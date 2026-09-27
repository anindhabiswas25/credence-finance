// Channel adapters against mocks at the HTTP boundary.
import webpush from "web-push";
import { describe, expect, it } from "vitest";
import { sendEmail } from "../src/channels/email.ts";
import { goneStatus, sendPush } from "../src/channels/push.ts";
import { sendTelegram } from "../src/channels/telegram.ts";
import { ChannelError } from "../src/channels/types.ts";
import { pushSubscriber } from "./fixtures.ts";

type Call = { url: string; init: RequestInit };

function mockFetch(respond: (c: Call) => Response) {
  const calls: Call[] = [];
  const f = (async (url: string | URL, init?: RequestInit) => {
    const c = { url: String(url), init: init ?? {} };
    calls.push(c);
    return respond(c);
  }) as typeof fetch;
  return { f, calls };
}

describe("email (Resend)", () => {
  it("posts the message with an idempotency key", async () => {
    const { f, calls } = mockFetch(() => Response.json({ id: "re_123" }));
    const id = await sendEmail(
      {
        apiKey: "re_test",
        apiUrl: "https://api.resend.test/",
        from: "Credence <a@b.c>",
      },
      { to: "priya@example.com", subject: "s", text: "t", html: "<p>t</p>" },
      "bell:1:email",
      f,
    );
    expect(id).toBe("re_123");
    expect(calls[0]!.url).toBe("https://api.resend.test/emails");
    const h = calls[0]!.init.headers as Record<string, string>;
    expect(h.authorization).toBe("Bearer re_test");
    expect(h["idempotency-key"]).toBe("bell:1:email");
    expect(JSON.parse(calls[0]!.init.body as string)).toMatchObject({
      to: ["priya@example.com"],
      subject: "s",
    });
  });

  it("classifies failures", async () => {
    const cfg = { apiKey: "k", apiUrl: "https://r", from: "f" };
    const msg = { to: "x@y.z", subject: "s", text: "t", html: "h" };
    for (const [status, permanent] of [
      [422, true],
      [401, true],
      [429, false],
      [503, false],
    ] as const) {
      const { f } = mockFetch(() => new Response("err", { status }));
      const e = await sendEmail(cfg, msg, "k", f).catch((e) => e);
      expect(e).toBeInstanceOf(ChannelError);
      expect(e.permanent).toBe(permanent);
    }
    const down = (async () => {
      throw new TypeError("fetch failed");
    }) as unknown as typeof fetch;
    const e = await sendEmail(cfg, msg, "k", down).catch((e) => e);
    expect(e.permanent).toBe(false);
  });
});

describe("web push (VAPID)", () => {
  it("encrypts the payload for the subscription and signs a VAPID JWT", async () => {
    const vapid = webpush.generateVAPIDKeys();
    const s = pushSubscriber("https://push.example/sub/1");
    const { f, calls } = mockFetch(
      () => new Response(null, { status: 201, headers: { location: "/m/1" } }),
    );
    const id = await sendPush(
      {
        publicKey: vapid.publicKey,
        privateKey: vapid.privateKey,
        subject: "mailto:ops@credence.finance",
      },
      s.sub,
      { title: "NVDA", body: "repay $2,896.78" },
      3600,
      f,
    );
    expect(id).toBe("/m/1");
    const c = calls[0]!;
    expect(c.url).toBe("https://push.example/sub/1");
    const h = c.init.headers as Record<string, string>;
    expect(h["Content-Encoding"]).toBe("aes128gcm");
    expect(h.TTL).toBe("3600");
    expect(h.Urgency).toBe("high");
    expect(h.Authorization).toMatch(
      new RegExp(`^vapid t=[\\w-]+\\.[\\w-]+\\.[\\w-]+, k=${vapid.publicKey}$`),
    );
    expect(s.decrypt(Buffer.from(c.init.body as Uint8Array))).toEqual({
      title: "NVDA",
      body: "repay $2,896.78",
    });
  });

  it("410 Gone is permanent and marks the subscription for deletion", async () => {
    const vapid = webpush.generateVAPIDKeys();
    const s = pushSubscriber("https://push.example/sub/2");
    const { f } = mockFetch(() => new Response("gone", { status: 410 }));
    const e = await sendPush(
      { ...vapid, subject: "mailto:a@b.c" },
      s.sub,
      {},
      60,
      f,
    ).catch((e) => e);
    expect(e.permanent).toBe(true);
    expect(goneStatus(e)).toBe(true);
  });
});

describe("telegram", () => {
  it("sends and classifies", async () => {
    const { f, calls } = mockFetch(() =>
      Response.json({ ok: true, result: { message_id: 42 } }),
    );
    expect(
      await sendTelegram(
        { botToken: "123:abc", apiUrl: "https://tg.test" },
        "999",
        "hi",
        f,
      ),
    ).toBe("42");
    expect(calls[0]!.url).toBe("https://tg.test/bot123:abc/sendMessage");
    expect(JSON.parse(calls[0]!.init.body as string)).toMatchObject({
      chat_id: "999",
      text: "hi",
    });
    const blocked = mockFetch(
      () => new Response('{"ok":false,"error_code":403}', { status: 403 }),
    );
    expect(
      (
        await sendTelegram(
          { botToken: "t", apiUrl: "https://tg" },
          "1",
          "x",
          blocked.f,
        ).catch((e) => e)
      ).permanent,
    ).toBe(true);
  });
});
