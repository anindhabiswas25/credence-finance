"use client";

import { useEffect } from "react";
import { startInteractions } from "@/lib/ix/interactions";

/** Runs the page's scroll and load animations. Renders nothing. */
export function Interactions() {
  useEffect(() => {
    const root = document.documentElement;
    if (!root.classList.contains("ix")) return; // reduced motion: the page stays static
    try {
      return startInteractions();
    } catch (err) {
      // Never leave content hidden in its initial animation state.
      root.classList.remove("ix");
      console.error("landing interactions failed to start", err);
    }
  }, []);
  return null;
}
