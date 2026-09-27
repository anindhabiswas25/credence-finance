//! Pluggable signers (§10.1): AWS KMS in every real deployment (keys never leave KMS), or a local key
//! file for development only. A local key refuses to load unless the chain is a dev chain.

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

    pub fn is_local(&self) -> bool {
        !matches!(self, Self::Kms { .. })
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
            bail!("local signing keys are dev-only; chain {chain_id} requires a KMS key");
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

fn read_key_file(path: &Path) -> Result<PrivateKeySigner> {
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
}
