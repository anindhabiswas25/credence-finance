"use client";

import { ConnectButton } from "@rainbow-me/rainbowkit";
import { Icon } from "./Icon";

/** RainbowKit's connect button, drawn in the dashboard's own style (ink pill, Outfit, 16px radius). */
export function WalletButton() {
  return (
    <ConnectButton.Custom>
      {({ account, chain, openAccountModal, openChainModal, openConnectModal, mounted }) => {
        if (!mounted) return <span className="cx-wallet" aria-hidden style={{ visibility: "hidden" }} />;
        if (!account || !chain) {
          return (
            <button type="button" className="cx-wallet" onClick={openConnectModal}>
              <Icon name="lock" size={17} strokeWidth={1.9} />
              <span>Connect wallet</span>
            </button>
          );
        }
        if (chain.unsupported) {
          return (
            <button type="button" className="cx-wallet is-bad" onClick={openChainModal}>
              <Icon name="alert" size={17} strokeWidth={1.9} />
              <span>Wrong network</span>
            </button>
          );
        }
        return (
          <span className="cx-wallet-group">
            <button type="button" className="cx-wallet is-ghost" onClick={openChainModal} title="Switch network">
              {chain.hasIcon && chain.iconUrl ? <img src={chain.iconUrl} alt="" width={18} height={18} /> : <span className="cx-dot-net" />}
              <span className="cx-wallet-net">{chain.name}</span>
            </button>
            <button type="button" className="cx-wallet" onClick={openAccountModal}>
              <span>{account.displayName}</span>
            </button>
          </span>
        );
      }}
    </ConnectButton.Custom>
  );
}
