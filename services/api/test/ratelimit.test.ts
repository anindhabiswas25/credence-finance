// OFF-03 (QA-sec): per-IP limits must not trust a client-set X-Forwarded-For.
import { describe, expect, it } from "vitest";
import { clientIp } from "../src/ratelimit.ts";

const h = (xff?: string) => new Headers(xff ? { "x-forwarded-for": xff } : {});

describe("clientIp", () => {
  it("ignores X-Forwarded-For from a peer that is not a trusted proxy", () => {
    expect(clientIp(h("1.1.1.1"), "9.9.9.9")).toBe("9.9.9.9");
    expect(clientIp(h("1.1.1.1"), "9.9.9.9", ["10.0.0.1"])).toBe("9.9.9.9");
    expect(clientIp(h("1.1.1.1"), undefined)).toBe("unknown");
  });

  it("behind our proxy, takes the right-most hop the proxies did not add", () => {
    const proxies = ["10.0.0.1", "10.0.0.2"];
    // the client forged 1.1.1.1; the edge proxy appended the real 5.5.5.5, the inner proxy 10.0.0.1
    expect(clientIp(h("1.1.1.1, 5.5.5.5, 10.0.0.1"), "10.0.0.2", proxies)).toBe(
      "5.5.5.5",
    );
    expect(clientIp(h("5.5.5.5"), "::ffff:10.0.0.1", proxies)).toBe("5.5.5.5");
    // a proxy with no header: the proxy itself
    expect(clientIp(h(), "10.0.0.1", proxies)).toBe("10.0.0.1");
  });
});
