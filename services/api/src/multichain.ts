// ADR-0014: one API for both chains. Each served chain has its own app (its indexer views, RPC, calendars); this
// dispatcher picks one by `?chain=<chainId>`:
// - a chain-bound route (markets, positions, auctions, settlements, pools, clock, risk, …) needs `chain` when
//   several chains are served; with one chain it defaults to it (the local devnode flow is unchanged);
// - an unknown `chain` is a 400 naming the served chains;
// - chain-agnostic routes (health, metrics, OpenAPI, SIWE, /v1/me, the testnet allowlist) go to the first chain's
//   app when no chain is given: sessions, accounts and preferences are per address, in one database;
// - every JSON object a chain-bound route returns carries `chainId`, so the same wallet on two chains never
//   reads as one position.
import { Hono } from "hono";

const AGNOSTIC = [
  /^\/healthz$/,
  /^\/readyz$/,
  /^\/metrics$/,
  /^\/v1\/openapi\.json$/,
  /^\/v1\/auth\//,
  /^\/v1\/me(\/|$)/,
  /^\/v1\/testnet\//,
];

export const isChainAgnostic = (path: string) =>
  AGNOSTIC.some((r) => r.test(path));

export interface ChainApp {
  chainId: number;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  app: { fetch: (req: Request, env?: any) => Response | Promise<Response> };
}

/** The top-level app. `apps[0]` is the default chain. `before` registers routes the dispatcher must not
 * handle (the WebSocket upgrade, which picks its own chain). */
export function createMultiChainApp(
  apps: ChainApp[],
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  before?: (top: Hono<any>) => void,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
): Hono<any> {
  if (apps.length === 0) throw new Error("no chain served");
  const byId = new Map(apps.map((a) => [a.chainId, a.app]));
  const served = apps.map((a) => a.chainId);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const top = new Hono<any>();
  before?.(top);
  top.all("*", async (c) => {
    const q = c.req.query("chain");
    const path = c.req.path;
    const agnostic = isChainAgnostic(path);
    let id: number;
    if (q === undefined) {
      if (apps.length > 1 && !agnostic)
        return c.json(
          {
            error: "bad_request",
            message: `chain is required: one of ${served.join(", ")}`,
          },
          400,
        );
      id = served[0]!;
    } else {
      id = Number(q);
      if (!byId.has(id))
        return c.json(
          {
            error: "bad_request",
            message: `unknown chain ${q}: one of ${served.join(", ")}`,
          },
          400,
        );
    }
    if (agnostic) return byId.get(id)!.fetch(c.req.raw, c.env);
    // the chain's app never sees `chain` (its routes validate their own query strictly)
    const url = new URL(c.req.url);
    url.searchParams.delete("chain");
    const res = await byId.get(id)!.fetch(new Request(url, c.req.raw), c.env);
    return withChainId(res, id);
  });
  return top;
}

/** Add `chainId` to a JSON object body (arrays and other bodies pass through). */
async function withChainId(res: Response, chainId: number): Promise<Response> {
  if (!res.headers.get("content-type")?.includes("application/json"))
    return res;
  const text = await res.text();
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    return new Response(text, res);
  }
  if (!body || typeof body !== "object" || Array.isArray(body))
    return new Response(text, res);
  const headers = new Headers(res.headers);
  headers.delete("content-length");
  return new Response(JSON.stringify({ chainId, ...body }), {
    status: res.status,
    statusText: res.statusText,
    headers,
  });
}
