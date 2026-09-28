// Browsers / bundlers (web app): fetch + instantiate the wasm once; `await ready` before the first call.
import init from "./web/credence_risk_wasm.js";
export * from "./web/credence_risk_wasm.js";
export const ready = init().then(() => undefined);
