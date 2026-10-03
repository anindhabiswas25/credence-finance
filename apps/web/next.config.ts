import type { NextConfig } from "next";

/** The Credence API (services/api). The browser calls /v1/* here, so the SIWE cookie stays first-party. */
const API_URL = process.env.CREDENCE_API_URL ?? "http://localhost:8787";


const nextConfig: NextConfig = {
  reactStrictMode: true,
  // The Base Account wallet isn't offered; its SDK's Node entry breaks the SSR build (lib/base-account-stub.js).
  turbopack: { resolveAlias: { "@base-org/account": "./lib/base-account-stub.js" } },
  async rewrites() {
    return [{ source: "/v1/:path*", destination: `${API_URL}/v1/:path*` }];
  },
};

export default nextConfig;
