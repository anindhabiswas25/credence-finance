// Node (API, SDK tests): the wasm is loaded synchronously by the CommonJS glue, so `ready` is already resolved.
export * from "./node/credence_risk_wasm.js";
export const ready = Promise.resolve();
