import type { ReactNode } from "react";
import "./webflow.css";
import "./landing.css";

/** The marketing site. Its Webflow stylesheet is scoped here so it never reaches the app. */
export default function MarketingLayout({ children }: { children: ReactNode }) {
  return children;
}
