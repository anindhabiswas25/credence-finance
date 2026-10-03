"use client";

import { useEffect, useState } from "react";

/**
 * On/off preferences, remembered on this device until accounts can store them.
 * Storage can be unavailable (private windows), so every access is guarded.
 */
export function Prefs({ storageKey, options }: { storageKey: string; options: { id: string; label: string; initial: boolean }[] }) {
  const [state, setState] = useState<Record<string, boolean>>(() =>
    Object.fromEntries(options.map((o) => [o.id, o.initial])),
  );

  useEffect(() => {
    try {
      const saved = JSON.parse(localStorage.getItem(storageKey) ?? "null") as Record<string, boolean> | null;
      if (saved) setState((s) => ({ ...s, ...saved }));
    } catch {
      /* no storage: keep defaults */
    }
  }, [storageKey]);

  const toggle = (id: string) =>
    setState((s) => {
      const next = { ...s, [id]: !s[id] };
      try {
        localStorage.setItem(storageKey, JSON.stringify(next));
      } catch {
        /* no storage: the change lasts for this visit */
      }
      return next;
    });

  return (
    <div style={{ display: "grid", gap: 16 }}>
      {options.map((o) => (
        <label key={o.id} className="cx-switch">
          <span>{o.label}</span>
          <input type="checkbox" role="switch" checked={!!state[o.id]} onChange={() => toggle(o.id)} />
        </label>
      ))}
    </div>
  );
}
