// Telegram Bot API sendMessage. 400 (chat not found) and 403 (bot blocked) are permanent.
import { type Fetch, httpError, post } from "./types.ts";

export interface TelegramConfig {
  botToken: string;
  apiUrl: string;
}

export async function sendTelegram(
  cfg: TelegramConfig,
  chatId: string,
  text: string,
  f: Fetch = fetch,
): Promise<string> {
  const res = await post(
    f,
    `${cfg.apiUrl.replace(/\/$/, "")}/bot${cfg.botToken}/sendMessage`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        chat_id: chatId,
        text,
        disable_web_page_preview: true,
      }),
    },
    "telegram",
  );
  const body = await res.text();
  if (!res.ok) throw httpError("telegram", res.status, body);
  const r = JSON.parse(body) as {
    ok: boolean;
    result?: { message_id?: number };
  };
  return String(r.result?.message_id ?? "ok");
}
