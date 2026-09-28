// Fund the relayer's and the keeper's own senders before anything else runs (seeding step 0).
import { parseEther, type Address } from "viem";
import { dev, pub } from "./lib.ts";

for (const a of process.argv.slice(2) as Address[]) {
  if ((await pub.getBalance({ address: a })) < parseEther("0.5"))
    await pub.waitForTransactionReceipt({
      hash: await dev.sendTransaction({ to: a, value: parseEther("2") }),
    });
  console.log(`funded ${a}`);
}
