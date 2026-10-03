"use client";

import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useAccount } from "wagmi";
import { GradientCard, H, KV, Note, PageHead, Pill, StatBlock, num, usd } from "../ui";
import { ConnectNote } from "./shared";
import { useApp } from "@/lib/app";
import { usePoolChain, useTokenBalance, useVaultChain } from "@/lib/chain";
import { STACKS, shortAddress } from "@/lib/protocol";
import { useSiwe } from "@/lib/siwe";

export function AccountView() {
  const { address, chain, connector, isConnected } = useAccount();
  const { loans } = useApp();
  const siwe = useSiwe();
  const eqVault = useVaultChain("equity", address);
  const navVault = useVaultChain("nav", address);
  const eqPool = usePoolChain("equity", address);
  const navPool = usePoolChain("nav", address);
  const tusdg = useTokenBalance(STACKS.equity.chainId, STACKS.equity.loanToken, address, 6);
  const usdc = useTokenBalance(STACKS.nav.chainId, STACKS.nav.loanToken, address, 6);
  const collateral = loans.reduce((a, l) => a + l.p.value, 0);
  const debt = loans.reduce((a, l) => a + l.p.debt, 0);
  const vault = eqVault.position + navVault.position;
  const pool = eqPool.position + navPool.position;
  const net = collateral - debt + vault + pool;

  return (
    <>
      <PageHead title="Account" sub="Your wallet and everything it holds across Credence, on both testnet chains." />
      <div className="cx-grid">
        <div className="cx-col">
          <section>
            <H>Wallet</H>
            {!isConnected || !address ? (
              <ConnectNote>Connect any EVM wallet to use Credence on testnet.</ConnectNote>
            ) : (
              <div className="cx-row">
                <GradientCard
                  tag={chain?.name ?? "Unsupported network"}
                  big={shortAddress(address)}
                  label="Wallet"
                  value={connector?.name ?? "Connected"}
                  pill={siwe.signedIn ? <Pill tone="good">Signed in</Pill> : <Pill tone="soft">Connected</Pill>}
                />
              </div>
            )}
          </section>
          {isConnected && (
            <>
              <section>
                <H>Positions</H>
                <KV
                  rows={[
                    ["Collateral", usd(collateral, 2)],
                    ["Debt", usd(debt, 2)],
                    ["Senior Vault", `${num(eqVault.position)} tUSDG · ${num(navVault.position)} USDC`],
                    ["Underwriter Pool", `${num(eqPool.position)} tUSDG · ${num(navPool.position)} USDC`],
                  ]}
                />
              </section>
              <section>
                <H>Wallet balances</H>
                <KV
                  rows={[
                    [`tUSDG · ${STACKS.equity.chainName}`, num(tusdg.value)],
                    [`USDC · ${STACKS.nav.chainName}`, num(usdc.value)],
                  ]}
                />
              </section>
            </>
          )}
          <Note icon="lock">
            Credence runs on two testnets: stock tokens on Robinhood Chain, the Treasury fund on Arbitrum Sepolia. Your wallet switches
            network for you when an action needs it.
          </Note>
        </div>
        <aside className="cx-aside">
          <StatBlock label="Net position" value={usd(net, 0)} chip="All roles" />
          <ConnectButton.Custom>
            {({ openAccountModal, openConnectModal, mounted }) => (
              <button type="button" className="cx-btn" disabled={!mounted} onClick={isConnected ? openAccountModal : openConnectModal}>
                {isConnected ? "Manage wallet" : "Connect wallet"}
              </button>
            )}
          </ConnectButton.Custom>
          {siwe.signedIn && (
            <button type="button" className="cx-btn is-ghost" onClick={siwe.signOut}>
              Sign out
            </button>
          )}
        </aside>
      </div>
    </>
  );
}
