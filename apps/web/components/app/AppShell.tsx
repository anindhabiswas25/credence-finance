"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useState, type FormEvent, type ReactNode } from "react";
import { Icon } from "./Icon";
import { WalletButton } from "./WalletButton";
import { useInbox } from "@/lib/api";
import { useSiwe } from "@/lib/siwe";

type NavItem = { href: string; label: string; icon: string; activeIcon?: string; badge?: number };

/** One sidebar entry per user in the docs (Architecture §1.4), plus alerts. */
const NAV: NavItem[] = [
  { href: "/app", label: "Overview", icon: "house-line", activeIcon: "house" },
  { href: "/app/markets", label: "Markets", icon: "markets" },
  { href: "/app/borrow", label: "Borrow", icon: "card" },
  { href: "/app/lend", label: "Lend", icon: "vault" },
  { href: "/app/underwrite", label: "Underwrite", icon: "shield-plain" },
  { href: "/app/auctions", label: "Auctions", icon: "gavel" },
  { href: "/app/risk", label: "Risk", icon: "pie" },
  { href: "/app/alerts", label: "Alerts", icon: "mail" },
];
const NAV_BOTTOM: NavItem[] = [
  { href: "/app/faucet", label: "Faucet", icon: "cash" },
  { href: "/app/account", label: "Account", icon: "user" },
  { href: "/app/settings", label: "Settings", icon: "settings" },
];

function NavList({ items, pathname, unread = 0 }: { items: NavItem[]; pathname: string; unread?: number }) {
  return (
    <>
      {items.map((item) => {
        const active = item.href === "/app" ? pathname === "/app" : pathname.startsWith(item.href);
        const badge = item.href === "/app/alerts" ? unread : item.badge;
        return (
          <Link key={item.href} href={item.href} aria-current={active ? "page" : undefined}>
            <Icon name={active && item.activeIcon ? item.activeIcon : item.icon} size={26} strokeWidth={1.6} />
            <span>{item.label}</span>
            {badge ? (
              <span className="cx-badge" aria-label={`${badge} unread`}>
                {badge}
              </span>
            ) : null}
          </Link>
        );
      })}
    </>
  );
}

export function AppShell({ children }: { children: ReactNode }) {
  const pathname = usePathname();
  const router = useRouter();
  const [menuOpen, setMenuOpen] = useState(false);
  const { signedIn } = useSiwe();
  const unread = useInbox(signedIn).data?.unread ?? 0;

  useEffect(() => setMenuOpen(false), [pathname]);

  const onSearch = (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const q = String(new FormData(e.currentTarget).get("q") ?? "").trim();
    router.push(q ? `/app/markets?q=${encodeURIComponent(q)}` : "/app/markets");
  };

  return (
    <div className="cx-body">
      <div className={`cx-frame${menuOpen ? " is-menu-open" : ""}`}>
        <a href="/" className="cx-brand" aria-label="Credence Finance home">
          <img src="/landing/mark-ink.svg" alt="" />
          <span>Credence</span>
        </a>

        <div className="cx-topbar">
          <form className="cx-search" role="search" onSubmit={onSearch}>
            <Icon name="search" size={19} strokeWidth={2} />
            <input name="q" type="search" placeholder="Search markets" aria-label="Search markets" />
          </form>
          <span className="cx-preview" title="Robinhood Chain testnet and Arbitrum Sepolia: test tokens only">
            Testnet
          </span>
          <div className="cx-topbar-right">
            <WalletButton />
            <span className="cx-lang">EN</span>
            <Link href="/app/alerts" className="cx-bell" aria-label={`Alerts, ${unread} unread`} data-unread={unread ? "" : undefined}>
              <Icon name="bell" size={26} strokeWidth={1.6} />
            </Link>
            <Link href="/app/account" className="cx-avatar" aria-label="Account" />
            <button
              type="button"
              className="cx-menu-btn"
              aria-expanded={menuOpen}
              aria-label="Menu"
              onClick={() => setMenuOpen((o) => !o)}
            >
              <Icon name={menuOpen ? "close" : "menu"} size={22} strokeWidth={2} />
            </button>
          </div>
        </div>

        <aside className="cx-side" aria-label="App">
          <nav className="cx-nav">
            <NavList items={NAV} pathname={pathname} unread={unread} />
          </nav>
          <nav className="cx-nav cx-nav-bottom">
            <NavList items={NAV_BOTTOM} pathname={pathname} />
          </nav>
        </aside>

        <main className="cx-main">{children}</main>
      </div>
    </div>
  );
}
