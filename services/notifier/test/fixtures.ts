// Shared test fixtures.
import { createECDH, randomBytes } from "node:crypto";
import ece from "http_ece";

// Scenario A (Appendix A) in base units, with the engine's rounding (cures rounded UP on-chain):
//  G-10 Priya NVDA: D 67,028.99, q 500, V 180, LTV_s 0.712580117506 → repay 2,896.779424…, add 22.584434…
//  G-11 Maya  TSLA: D 55,535.10, q 300, V 250, LTV_s 0.626773490008 → repay 8,527.088249…, add 54.418946…
// (test/e2e.test.ts recomputes the same values with risk-cli and checks they are equal)
export const PRIYA = {
  cureRepay: "2896779425",
  cureCollateral: "22584434549062858424",
  ltv: "744766555555555556",
  safeLtv: "712580117506000000",
};
export const MAYA = {
  cureRepay: "8527088250",
  cureCollateral: "54418946463681239021",
  ltv: "740468000000000000",
  safeLtv: "626773490008000000",
};

/** A browser-side push subscription whose private key we keep, so the test can decrypt. */
export function pushSubscriber(endpoint: string) {
  const ecdh = createECDH("prime256v1");
  ecdh.generateKeys();
  const auth = randomBytes(16);
  return {
    sub: {
      endpoint,
      p256dh: ecdh.getPublicKey().toString("base64url"),
      auth: auth.toString("base64url"),
    },
    decrypt(body: Buffer): unknown {
      return JSON.parse(
        ece
          .decrypt(body, {
            version: "aes128gcm",
            privateKey: ecdh,
            authSecret: auth,
          })
          .toString(),
      );
    },
  };
}
