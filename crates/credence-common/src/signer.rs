//! Pluggable signers (§10.1, ADR-0014): one key per (chain, role), behind one interface.
//! * **Encrypted keystore** (the free default for testnet): a Web3 Secret Storage v3 file (what `cast wallet
//!   import` writes), unlocked at start from a password file only the service user can read (mode 0600).
//! * **AWS KMS** (optional; keys never leave KMS).
//! * A plain key file or hex key: dev chains only. A key in env or a plain file never loads on a real chain.

use crate::{env, is_dev_chain};
use alloy::{
    network::EthereumWallet,
    primitives::{Address, Signature, B256},
    signers::{aws::AwsSigner, local::PrivateKeySigner, Signer},
};
use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};

/// Where a signing key lives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SignerConfig {
    /// AWS KMS key id or ARN (secp256k1, `ECC_SECG_P256K1`, `SIGN_VERIFY`).
    Kms { key_id: String },
    /// Encrypted keystore (Web3 Secret Storage v3) and the file holding its password (both mode 0600).
    Keystore {
        path: PathBuf,
        password_file: PathBuf,
    },
    /// File holding a hex private key. Dev chains only.
    LocalKeyFile { path: PathBuf },
    /// Hex private key held in memory. Tests and dev chains only.
    LocalHex { key: String },
}

impl SignerConfig {
    /// Resolve from env: `<prefix>_KMS_KEY_ID` wins, then `<prefix>_KEY_FILE`, then `<prefix>_PRIVATE_KEY`.
    pub fn from_env(prefix: &str) -> Result<Self> {
        if let Some(key_id) = env::optional(&format!("{prefix}_KMS_KEY_ID")) {
            return Ok(Self::Kms { key_id });
        }
        if let Some(path) = env::optional(&format!("{prefix}_KEY_FILE")) {
            return Ok(Self::LocalKeyFile { path: path.into() });
        }
        if let Some(key) = env::optional(&format!("{prefix}_PRIVATE_KEY")) {
            return Ok(Self::LocalHex { key });
        }
        bail!("no signer configured: set {prefix}_KMS_KEY_ID (or {prefix}_KEY_FILE on a dev chain)")
    }

    /// ADR-0014: `from_env`, then the per-chain, per-role keystore `$KEYSTORE_DIR/<chainId>/<role>.json` with its
    /// password in `<role>.password` next to it. `role` names the key, e.g. `keeper`, `relayer-a-submitter`,
    /// `relayer-a-n1`, `solver`: every chain and role has its own key.
    pub fn resolve(prefix: &str, chain_id: u64, role: &str) -> Result<Self> {
        Self::resolve_from(prefix, chain_id, role, env::optional)
    }

    /// `resolve` over any variable source (testable).
    pub fn resolve_from(
        prefix: &str,
        chain_id: u64,
        role: &str,
        get: impl Fn(&str) -> Option<String>,
    ) -> Result<Self> {
        if let Some(key_id) = get(&format!("{prefix}_KMS_KEY_ID")) {
            return Ok(Self::Kms { key_id });
        }
        if let Some(path) = get(&format!("{prefix}_KEYSTORE")) {
            let path = PathBuf::from(path);
            let password_file = get(&format!("{prefix}_KEYSTORE_PASSWORD_FILE"))
                .map(PathBuf::from)
                .unwrap_or_else(|| path.with_extension("password"));
            return Ok(Self::Keystore {
                path,
                password_file,
            });
        }
        if let Some(dir) = get("KEYSTORE_DIR") {
            anyhow::ensure!(
                !role.is_empty()
                    && role
                        .chars()
                        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'),
                "bad key role {role:?}"
            );
            let base = PathBuf::from(dir).join(chain_id.to_string());
            let path = base.join(format!("{role}.json"));
            if path.exists() {
                return Ok(Self::Keystore {
                    password_file: base.join(format!("{role}.password")),
                    path,
                });
            }
        }
        if let Some(path) = get(&format!("{prefix}_KEY_FILE")) {
            return Ok(Self::LocalKeyFile { path: path.into() });
        }
        if let Some(key) = get(&format!("{prefix}_PRIVATE_KEY")) {
            return Ok(Self::LocalHex { key });
        }
        bail!(
            "no signer for {role} on chain {chain_id}: put a keystore at $KEYSTORE_DIR/{chain_id}/{role}.json \
             (+ {role}.password), or set {prefix}_KEYSTORE or {prefix}_KMS_KEY_ID"
        )
    }

    /// A key held in plain form (a hex key or an unencrypted file): dev chains only.
    pub fn is_local(&self) -> bool {
        matches!(self, Self::LocalKeyFile { .. } | Self::LocalHex { .. })
    }
}

/// A signer usable both for EIP-712 report signatures and for sending transactions.
#[derive(Clone, Debug)]
pub enum CredenceSigner {
    Local(PrivateKeySigner),
    Aws(AwsSigner),
}

impl CredenceSigner {
    pub async fn load(cfg: &SignerConfig, chain_id: u64) -> Result<Self> {
        if cfg.is_local() && !is_dev_chain(chain_id) {
            bail!(
                "plain signing keys are dev-only; chain {chain_id} needs an encrypted keystore or a KMS key"
            );
        }
        let signer = match cfg {
            SignerConfig::Kms { key_id } => {
                let sdk = aws_config::load_from_env().await;
                let client = alloy::signers::aws::aws_sdk_kms::Client::new(&sdk);
                let s = AwsSigner::new(client, key_id.clone(), Some(chain_id))
                    .await
                    .with_context(|| format!("loading KMS key {key_id}"))?;
                Self::Aws(s)
            }
            SignerConfig::Keystore {
                path,
                password_file,
            } => {
                require_private(path)?;
                require_private(password_file)?;
                let password = std::fs::read_to_string(password_file)
                    .with_context(|| format!("reading {}", password_file.display()))?;
                let s = PrivateKeySigner::decrypt_keystore(
                    path,
                    password.trim_end_matches(['\n', '\r']),
                )
                .with_context(|| format!("unlocking {}", path.display()))?;
                Self::Local(s.with_chain_id(Some(chain_id)))
            }
            SignerConfig::LocalKeyFile { path } => {
                Self::Local(read_key_file(path)?.with_chain_id(Some(chain_id)))
            }
            SignerConfig::LocalHex { key } => Self::Local(
                key.parse::<PrivateKeySigner>()
                    .context("bad hex key")?
                    .with_chain_id(Some(chain_id)),
            ),
        };
        Ok(signer)
    }

    pub fn address(&self) -> Address {
        match self {
            Self::Local(s) => s.address(),
            Self::Aws(s) => s.address(),
        }
    }

    /// Sign a 32-byte digest (no EIP-191 prefix). Signatures are normalised to low-s.
    pub async fn sign_hash(&self, hash: &B256) -> Result<Signature> {
        let sig = match self {
            Self::Local(s) => s.sign_hash(hash).await?,
            Self::Aws(s) => s.sign_hash(hash).await?,
        };
        Ok(sig.normalized_s())
    }

    pub fn wallet(&self) -> EthereumWallet {
        match self {
            Self::Local(s) => EthereumWallet::from(s.clone()),
            Self::Aws(s) => EthereumWallet::from(s.clone()),
        }
    }
}

/// A secret file must not be readable by group or others.
fn require_private(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(path)
            .with_context(|| format!("{}", path.display()))?
            .permissions()
            .mode();
        if mode & 0o077 != 0 {
            bail!(
                "{} must not be readable by group/others (chmod 600)",
                path.display()
            );
        }
    }
    Ok(())
}

fn read_key_file(path: &Path) -> Result<PrivateKeySigner> {
    require_private(path)?;
    let raw =
        std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    raw.trim()
        .parse::<PrivateKeySigner>()
        .with_context(|| format!("{} is not a hex private key", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::keccak256;

    const ANVIL0: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

    #[tokio::test]
    async fn local_key_refused_on_testnet() {
        let cfg = SignerConfig::LocalHex { key: ANVIL0.into() };
        assert!(CredenceSigner::load(&cfg, crate::ARB_SEPOLIA)
            .await
            .is_err());
        assert!(CredenceSigner::load(&cfg, 31_337).await.is_ok());
    }

    #[tokio::test]
    async fn key_file_requires_0600_and_signs_low_s() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("k");
        std::fs::write(&p, format!("{ANVIL0}\n")).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o644)).unwrap();
            assert!(
                CredenceSigner::load(&SignerConfig::LocalKeyFile { path: p.clone() }, 31_337)
                    .await
                    .is_err()
            );
            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        let s = CredenceSigner::load(&SignerConfig::LocalKeyFile { path: p }, 31_337)
            .await
            .unwrap();
        assert_eq!(
            s.address(),
            "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
                .parse::<Address>()
                .unwrap()
        );
        let h = keccak256(b"credence");
        let sig = s.sign_hash(&h).await.unwrap();
        assert_eq!(sig.recover_address_from_prehash(&h).unwrap(), s.address());
        assert!(
            sig.normalize_s().is_none(),
            "signature must already be low-s"
        );
    }

    #[tokio::test]
    async fn keystore_per_chain_and_role_loads_on_testnet_and_needs_private_files() {
        let dir = tempfile::tempdir().unwrap();
        let chain = crate::ARB_SEPOLIA;
        let base = dir.path().join(chain.to_string());
        std::fs::create_dir_all(&base).unwrap();
        let mut rng = rand::thread_rng();
        let pk = alloy::primitives::hex::decode(&ANVIL0[2..]).unwrap();
        PrivateKeySigner::encrypt_keystore(&base, &mut rng, &pk, "pw-keeper", Some("keeper.json"))
            .unwrap();
        let (ks, pw) = (base.join("keeper.json"), base.join("keeper.password"));
        std::fs::write(&pw, "pw-keeper\n").unwrap();
        let env = |k: &str| (k == "KEYSTORE_DIR").then(|| dir.path().display().to_string());
        let cfg = SignerConfig::resolve_from("KEEPER", chain, "keeper", env).unwrap();
        assert_eq!(
            cfg,
            SignerConfig::Keystore {
                path: ks.clone(),
                password_file: pw.clone()
            }
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            for f in [&ks, &pw] {
                std::fs::set_permissions(f, std::fs::Permissions::from_mode(0o600)).unwrap();
            }
            std::fs::set_permissions(&pw, std::fs::Permissions::from_mode(0o640)).unwrap();
            assert!(
                CredenceSigner::load(&cfg, chain).await.is_err(),
                "a group-readable password file"
            );
            std::fs::set_permissions(&pw, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        let s = CredenceSigner::load(&cfg, chain).await.unwrap();
        assert_eq!(
            s.address(),
            "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
                .parse::<Address>()
                .unwrap()
        );
        // another chain or another role has no key there: a clear error, never a fallback to someone else's key
        let err = SignerConfig::resolve_from("KEEPER", 46_630, "keeper", env).unwrap_err();
        assert!(err.to_string().contains("46630/keeper.json"), "{err}");
        assert!(SignerConfig::resolve_from("RELAYER_NODE", chain, "relayer-a-n1", env).is_err());
        assert!(SignerConfig::resolve_from("X", chain, "../keeper", env).is_err());
        // a wrong password fails
        std::fs::write(&pw, "nope").unwrap();
        assert!(CredenceSigner::load(&cfg, chain).await.is_err());
    }

    #[test]
    fn kms_and_explicit_keystore_win_over_the_directory() {
        let env = |k: &str| match k {
            "KEEPER_KMS_KEY_ID" => Some("arn:k".to_string()),
            "KEYSTORE_DIR" => Some("/nonexistent".to_string()),
            _ => None,
        };
        assert_eq!(
            SignerConfig::resolve_from("KEEPER", 1, "keeper", env).unwrap(),
            SignerConfig::Kms {
                key_id: "arn:k".into()
            }
        );
        let env = |k: &str| (k == "KEEPER_KEYSTORE").then(|| "/k/keeper.json".to_string());
        assert_eq!(
            SignerConfig::resolve_from("KEEPER", 1, "keeper", env).unwrap(),
            SignerConfig::Keystore {
                path: "/k/keeper.json".into(),
                password_file: "/k/keeper.password".into()
            }
        );
    }
}
