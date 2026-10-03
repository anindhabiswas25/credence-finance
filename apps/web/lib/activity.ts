"use client";
/**
 * The actions this wallet took from this device, newest first. The API has no per-wallet history
 * endpoint yet, so "Recent activity" lists what was sent from here. Storage can be unavailable
 * (private windows), so every access is guarded.
 */
import { useEffect, useState } from "react";

export type Activity = {
  icon: string;
  title: string;
  amount: string;
  /** borrow | lend | underwrite | auction | faucet */
  kind: string;
  chainId: number;
  hash: string;
  when: number;
};

const key = (address: string) => `cx-activity-${address.toLowerCase()}`;
const EVENT = "cx-activity";

export function readActivity(address: string): Activity[] {
  try {
    return JSON.parse(localStorage.getItem(key(address)) ?? "[]") as Activity[];
  } catch {
    return [];
  }
}

export function logActivity(address: string, a: Activity) {
  try {
    localStorage.setItem(key(address), JSON.stringify([a, ...readActivity(address)].slice(0, 100)));
    window.dispatchEvent(new Event(EVENT));
  } catch {
    /* no storage: the action still went through */
  }
}

export function useActivity(address: string | undefined, kind?: string) {
  const [items, setItems] = useState<Activity[]>([]);
  useEffect(() => {
    if (!address) return setItems([]);
    const load = () => setItems(readActivity(address).filter((a) => !kind || a.kind === kind));
    load();
    window.addEventListener(EVENT, load);
    return () => window.removeEventListener(EVENT, load);
  }, [address, kind]);
  return items;
}

/** A small JSON record per wallet (bids, withdrawal tickets) kept on this device. */
export function useLocalRecords<T>(name: string, address: string | undefined) {
  const k = address ? `cx-${name}-${address.toLowerCase()}` : null;
  const [items, setItems] = useState<T[]>([]);
  useEffect(() => {
    if (!k) return setItems([]);
    try {
      setItems(JSON.parse(localStorage.getItem(k) ?? "[]") as T[]);
    } catch {
      setItems([]);
    }
  }, [k]);
  const save = (next: T[]) => {
    setItems(next);
    try {
      if (k) localStorage.setItem(k, JSON.stringify(next));
    } catch {
      /* no storage */
    }
  };
  return [items, save] as const;
}
