# Sequencer down (RB-06: ChainHeadStale)

**Symptom:** `credence_keeper_chain_head_age_seconds` > 5 min on one chain: the latest block is old on every RPC.

1. Is it the chain or our RPCs? Compare every provider:
   ```sh
   make ops-rpc-check
   cast block latest --rpc-url https://sepolia-rollup.arbitrum.io/rpc -f timestamp   # 421614, keyless
   cast block latest --rpc-url https://rpc.testnet.chain.robinhood.com -f timestamp   # 46630, keyless
   ```
   If only our keyed providers are stale, it is an RPC outage: [rpc-outage.md](rpc-outage.md).
2. **The sequencer is down** (every endpoint, and the chain's status page agrees): nothing to do on our side. The contracts extend the phase deadlines automatically (R-20) once blocks resume, and the keepers resume by themselves.
3. After it resumes: check the extended deadlines (`curl -s 'http://127.0.0.1:8787/v1/clock/NVDA:XNAS?chain=46630' | jq '.state, .reopenAt'`), and that ChainHeadStale resolves within 2 min. If an asset is stuck in REOPEN, follow [keeper-enforce.md](keeper-enforce.md).
