"use client";

import "@rainbow-me/rainbowkit/styles.css";
import { RainbowKitProvider, connectorsForWallets, lightTheme } from "@rainbow-me/rainbowkit";
import {
  coinbaseWallet,
  injectedWallet,
  metaMaskWallet,
  rabbyWallet,
  rainbowWallet,
  walletConnectWallet,
} from "@rainbow-me/rainbowkit/wallets";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState, type ReactNode } from "react";
import { WagmiProvider, createConfig, http } from "wagmi";
import { CHAINS, arbSepolia, robinhoodTestnet } from "@/lib/protocol";

/** WalletConnect needs a project id (free at cloud.reown.com); without one, browser wallets still work. */
const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ?? "";

const connectors = connectorsForWallets(
  [
    {
      groupName: "Wallets",
      wallets: projectId
        ? [metaMaskWallet, rabbyWallet, coinbaseWallet, rainbowWallet, walletConnectWallet, injectedWallet]
        : [injectedWallet, rabbyWallet, coinbaseWallet],
    },
  ],
  { appName: "Credence Finance", projectId: projectId || "credence-testnet" },
);

export const wagmiConfig = createConfig({
  chains: CHAINS,
  connectors,
  transports: {
    [robinhoodTestnet.id]: http(),
    [arbSepolia.id]: http(),
  },
  ssr: true,
});

/** The dashboard's ink, radii and typeface, so the wallet modal looks like part of the app. */
const theme = {
  ...lightTheme({ accentColor: "#2e335b", accentColorForeground: "#fff", borderRadius: "large", overlayBlur: "small" }),
  fonts: { body: 'var(--font-outfit), "Outfit", system-ui, sans-serif' },
};

export function Providers({ children }: { children: ReactNode }) {
  const [queryClient] = useState(
    () => new QueryClient({ defaultOptions: { queries: { staleTime: 10_000, refetchOnWindowFocus: false } } }),
  );
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider theme={theme} modalSize="compact" appInfo={{ appName: "Credence Finance" }}>
          {children}
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
