// Mock email (Resend) and Telegram providers for scenario A: accept every message and append it to
// target/be/scenario-a/deliveries.jsonl. Usage: node mock-providers.ts <port>
import { appendFileSync } from "node:fs";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { OUT } from "./lib.ts";

const file = resolve(OUT, "deliveries.jsonl");
let n = 0;
createServer((req, res) => {
  const chunks: Buffer[] = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    n++;
    const path = req.url ?? "";
    appendFileSync(
      file,
      JSON.stringify({
        path,
        body: Buffer.concat(chunks).toString(),
        at: Date.now(),
      }) + "\n",
    );
    if (path.includes("/emails"))
      return void res.writeHead(200).end(JSON.stringify({ id: `re_${n}` }));
    if (path.includes("/sendMessage"))
      return void res
        .writeHead(200)
        .end(JSON.stringify({ ok: true, result: { message_id: n } }));
    res.writeHead(404).end();
  });
}).listen(Number(process.argv[2] ?? 18799), "127.0.0.1", () =>
  console.log(`mock providers on :${process.argv[2] ?? 18799}`),
);
