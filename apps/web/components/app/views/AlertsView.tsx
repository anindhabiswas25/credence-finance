"use client";

import { useQueryClient } from "@tanstack/react-query";
import { Icon } from "../Icon";
import { ConnectFirst } from "../actions";
import { Prefs } from "../Prefs";
import { H, KV, Note, PageHead, StatBlock } from "../ui";
import { ErrorNote, Loading } from "./shared";
import { api, useInbox } from "@/lib/api";
import { useApp } from "@/lib/app";
import { useSiwe } from "@/lib/siwe";
import { et, etShort, local } from "@/lib/time";

const ICON: [RegExp, string][] = [
  [/bell/i, "bell"],
  [/auction|bid|lot/i, "gavel"],
  [/epoch|pool|cover/i, "shield"],
  [/stress|halt|pause|alert|ops/i, "alert"],
  [/closure|clock|reopen/i, "clock"],
];
const iconOf = (event: string) => ICON.find(([re]) => re.test(event))?.[1] ?? "mail";

/** The sign-in gate for wallet-private pages: connect, then sign one message (SIWE). */
export function SignInGate({ why }: { why: string }) {
  const siwe = useSiwe();
  return (
    <div style={{ display: "grid", gap: 14, justifyItems: "start" }}>
      <Note icon="lock">{why}</Note>
      <ConnectFirst label="Connect wallet">
        <button type="button" className="cx-btn" aria-disabled={siwe.busy || undefined} onClick={() => !siwe.busy && siwe.signIn()}>
          {siwe.busy ? "Check your wallet…" : "Sign in with your wallet"}
        </button>
      </ConnectFirst>
      {siwe.error && <p className="cx-hint is-bad">{siwe.error}</p>}
    </div>
  );
}

export function AlertsView() {
  const { closure } = useApp();
  const siwe = useSiwe();
  const inbox = useInbox(siwe.signedIn);
  const qc = useQueryClient();
  const items = inbox.data?.items ?? [];
  const unread = inbox.data?.unread ?? 0;

  const markRead = async (ids?: string[]) => {
    await api("/v1/me/inbox/read", { method: "POST", body: JSON.stringify(ids ? { ids } : { all: true }) }).catch(() => undefined);
    await qc.invalidateQueries({ queryKey: ["inbox"] });
  };

  return (
    <>
      <PageHead title="Alerts" sub="Bell notices, closures, auction results and pool settlements for your positions." />
      <div className="cx-grid">
        <div className="cx-col">
          <section>
            <H
              right={
                siwe.signedIn && unread > 0 ? (
                  <button type="button" className="cx-chip" onClick={() => markRead()}>
                    Mark {unread} read
                  </button>
                ) : (
                  <small>{unread} unread</small>
                )
              }
            >
              Inbox
            </H>
            {!siwe.signedIn ? (
              <SignInGate why="Your inbox is private. Sign in with your wallet (one signature, no transaction) to read it." />
            ) : inbox.error ? (
              <ErrorNote error={inbox.error} />
            ) : inbox.isLoading ? (
              <Loading what="Loading your inbox" />
            ) : items.length === 0 ? (
              <Note icon="bell">No alerts yet. Bell notices for your loans arrive here before each risky close.</Note>
            ) : (
              <div>
                {items.map((a) => (
                  <article key={a.id} className="cx-alert" onClick={() => !a.read && markRead([a.id])} style={{ cursor: a.read ? undefined : "pointer" }}>
                    <span className="cx-tile-icon" style={{ width: 46, height: 46, margin: 0 }}>
                      <Icon name={iconOf(a.event)} size={22} strokeWidth={1.9} />
                    </span>
                    <div>
                      <h3>
                        {!a.read && <span className="cx-unread-dot" aria-label="Unread" />}
                        {a.subject}
                      </h3>
                      <p>{a.body}</p>
                    </div>
                    <time>{local(a.createdAt)}</time>
                  </article>
                ))}
              </div>
            )}
          </section>
        </div>
        <aside className="cx-aside">
          <StatBlock
            label={closure?.inProgress ? "Markets reopen" : "Next Bell deadline"}
            value={closure ? etShort(closure.inProgress ? closure.reopenAt : closure.bellDeadlineAt) : "—"}
            chip="ET"
          />
          <KV
            rows={[
              ["Bell window opens", et(closure?.bellWindowAt)],
              ["Market close", et(closure?.closeAt)],
              ["Reopen", et(closure?.reopenAt)],
            ]}
          />
          <div>
            <H>Notify me by</H>
            <KV
              rows={[
                ["In the app", "On"],
                ["Email", "Before mainnet"],
                ["Telegram", "Before mainnet"],
              ]}
            />
          </div>
          <div>
            <H>About</H>
            <Prefs
              storageKey="cx-alert-topics"
              options={[
                { id: "bell", label: "Bell checks for my loans", initial: true },
                { id: "reopen", label: "Reopen results", initial: true },
                { id: "stress", label: "Stress flags and halts", initial: true },
                { id: "epoch", label: "Pool epoch settlements", initial: false },
              ]}
            />
          </div>
          {siwe.signedIn && (
            <button type="button" className="cx-btn is-ghost" onClick={siwe.signOut}>
              Sign out of alerts
            </button>
          )}
        </aside>
      </div>
    </>
  );
}
