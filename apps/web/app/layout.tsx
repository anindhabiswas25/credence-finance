import type { Metadata, Viewport } from "next";
import { Inter, Manrope, Outfit } from "next/font/google";
import type { ReactNode } from "react";

const manrope = Manrope({ subsets: ["latin"], variable: "--font-manrope", display: "swap" });
const inter = Inter({ subsets: ["latin"], style: ["normal", "italic"], variable: "--font-inter", display: "swap" });
/** The dashboard typeface, used across the app. */
const outfit = Outfit({ subsets: ["latin"], variable: "--font-outfit", display: "swap" });

export const metadata: Metadata = {
  title: "Credence Finance",
  description:
    "Borrow USDC against tokenized stocks and Treasury funds. Every rule follows the market clock, so nobody is liquidated on a fake weekend price.",
  icons: { icon: "/landing/favicon.png", apple: "/landing/webclip.png" },
  openGraph: { type: "website", title: "Credence Finance" },
  twitter: { card: "summary_large_image", title: "Credence Finance" },
};

export const viewport: Viewport = { width: "device-width", initialScale: 1 };

/**
 * Runs before first paint. Adds Webflow's `w-mod-js` / `w-mod-touch` classes, and `ix`, which
 * holds animated elements in their initial state until the interactions start. Users who
 * prefer reduced motion get the static page.
 */
const bootScript = `(function(d,w){var c=d.documentElement.classList;c.add("w-mod-js");
if("ontouchstart" in w||(w.DocumentTouch&&d instanceof w.DocumentTouch))c.add("w-mod-touch");
if(!w.matchMedia("(prefers-reduced-motion: reduce)").matches)c.add("ix","w-mod-ix");})(document,window);`;

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" className={`${manrope.variable} ${inter.variable} ${outfit.variable}`} suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: bootScript }} />
      </head>
      <body>{children}</body>
    </html>
  );
}
