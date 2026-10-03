"use client";
/**
 * Sign-In with Ethereum against the API (`/v1/auth/siwe/*`). The session is an httpOnly cookie that
 * unlocks the alerts inbox and testnet access. Reading and transacting need no sign-in.
 */
import { useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { createSiweMessage } from "viem/siwe";
import { useAccount, useSignMessage } from "wagmi";
import { api, useSession } from "./api";
import { STACKS } from "./protocol";
import { humanError } from "./tx";

const SERVED = new Set<number>([STACKS.equity.chainId, STACKS.nav.chainId]);

export function useSiwe() {
  const qc = useQueryClient();
  const { address, chainId } = useAccount();
  const { signMessageAsync } = useSignMessage();
  const session = useSession();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const signedIn = !!session.data && !!address && session.data.address.toLowerCase() === address.toLowerCase();

  const signIn = async () => {
    if (!address) return;
    setBusy(true);
    setError(null);
    try {
      const { nonce, domain } = await api<{ nonce: string; domain: string }>("/v1/auth/siwe/nonce", { method: "POST" });
      const message = createSiweMessage({
        domain,
        address,
        statement: "Sign in to Credence Finance.",
        uri: window.location.origin,
        version: "1",
        chainId: chainId && SERVED.has(chainId) ? chainId : STACKS.equity.chainId,
        nonce,
      });
      const signature = await signMessageAsync({ message });
      await api("/v1/auth/siwe/verify", { method: "POST", body: JSON.stringify({ message, signature }) });
      await qc.invalidateQueries({ queryKey: ["session"] });
    } catch (e) {
      setError(humanError(e));
    } finally {
      setBusy(false);
    }
  };

  const signOut = async () => {
    await api("/v1/auth/logout", { method: "POST" }).catch(() => undefined);
    qc.setQueryData(["session"], null);
    qc.removeQueries({ queryKey: ["inbox"] });
    qc.removeQueries({ queryKey: ["me"] });
  };

  return { signedIn, signIn, signOut, busy, error, loading: session.isLoading };
}
