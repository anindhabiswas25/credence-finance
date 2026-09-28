export * from "./web/credence_risk_wasm.js";
/** Resolves once the wasm module is instantiated (already resolved on Node). Await it before the first call. */
export declare const ready: Promise<void>;
