// Export the devnode's on-chain calendars (CalendarStore) to calendar files (format v1) the keeper, the
// relayer and the API load (CALENDAR_FILES), so every service runs on the chain's synthetic sessions.
import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { keccak256, stringToHex } from "viem";
import { OUT, chainSessions } from "./lib.ts";

for (const venue of ["XNYS", "USBANK"]) {
  const sessions = await chainSessions(venue);
  const doc = {
    formatVersion: 1,
    venue,
    source: "on-chain CalendarStore (devnode synthetic)",
    count: sessions.length,
    coverageEnd: sessions.at(-1)?.extClose ?? 0,
    contentHash: keccak256(stringToHex(JSON.stringify(sessions))),
    sessions,
  };
  writeFileSync(resolve(OUT, `${venue}.json`), JSON.stringify(doc, null, 1));
  console.log(
    `calendar ${venue}: ${sessions.length} sessions → ${resolve(OUT, `${venue}.json`)}`,
  );
}
