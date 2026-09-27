// VAPID Web Push (RFC 8030 / 8291 / 8292). `web-push` builds the encrypted aes128gcm request and the
// VAPID JWT; the request itself goes through fetch, so tests can point a subscription at a local server.
import webpush from "web-push";
import { ChannelError, type Fetch, httpError, post } from "./types.ts";

export interface PushConfig {
  publicKey: string;
  privateKey: string;
  subject: string; // mailto: or https: contact
}

export interface PushSubscription {
  endpoint: string;
  p256dh: string;
  auth: string;
}

/** Deliver one push. 404/410 mean the subscription is gone (permanent: the caller deletes it). */
export async function sendPush(
  cfg: PushConfig,
  sub: PushSubscription,
  payload: object,
  ttlS: number,
  f: Fetch = fetch,
): Promise<string> {
  let req: webpush.RequestDetails;
  try {
    req = webpush.generateRequestDetails(
      { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
      JSON.stringify(payload),
      {
        vapidDetails: {
          subject: cfg.subject,
          publicKey: cfg.publicKey,
          privateKey: cfg.privateKey,
        },
        TTL: ttlS,
        urgency: "high",
        contentEncoding: "aes128gcm",
      },
    );
  } catch (e) {
    throw new ChannelError(
      `push: bad subscription: ${(e as Error).message}`,
      true,
    );
  }
  const res = await post(
    f,
    req.endpoint,
    {
      method: req.method,
      headers: Object.fromEntries(
        Object.entries(req.headers).map(([k, v]) => [k, String(v)]),
      ),
      body: req.body as Uint8Array,
    },
    "push",
  );
  const body = await res.text();
  if (!res.ok) throw httpError("push", res.status, body);
  return res.headers.get("location") ?? `${res.status}`;
}

export const goneStatus = (e: ChannelError) =>
  /^push (404|410):/.test(e.message);
