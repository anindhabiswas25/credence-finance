// Resend (https://resend.com/docs/api-reference/emails/send-email). The idempotency key makes a
// retried or reclaimed job safe: Resend returns the original email instead of sending twice.
import { type Fetch, httpError, post } from "./types.ts";

export interface EmailConfig {
  apiKey: string;
  apiUrl: string;
  from: string;
}

export interface Email {
  to: string;
  subject: string;
  text: string;
  html: string;
}

export async function sendEmail(
  cfg: EmailConfig,
  msg: Email,
  idempotencyKey: string,
  f: Fetch = fetch,
): Promise<string> {
  const res = await post(
    f,
    `${cfg.apiUrl.replace(/\/$/, "")}/emails`,
    {
      method: "POST",
      headers: {
        authorization: `Bearer ${cfg.apiKey}`,
        "content-type": "application/json",
        "idempotency-key": idempotencyKey,
      },
      body: JSON.stringify({
        from: cfg.from,
        to: [msg.to],
        subject: msg.subject,
        text: msg.text,
        html: msg.html,
      }),
    },
    "resend",
  );
  const body = await res.text();
  if (!res.ok) throw httpError("resend", res.status, body);
  const id = (JSON.parse(body) as { id?: string }).id;
  return id ?? "unknown";
}
