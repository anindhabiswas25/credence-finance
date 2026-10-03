// Stand-in for @base-org/account. wagmi's Base Account connector imports it lazily, and only when
// someone picks the "Base" wallet, which this app doesn't list. The real package's Node entry pulls
// Coinbase's server SDK (and its optional x402 packages) into the SSR build, so it is aliased here.
export function createBaseAccountSDK() {
  throw new Error("The Base Account wallet isn't available in Credence.");
}
