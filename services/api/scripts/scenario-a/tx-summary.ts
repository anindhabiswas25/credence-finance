// Keeper tx summary for the scenario A report: mined / reverted / replaced / dropped, by job family
// (the job key up to its first ':' plus the step name, e.g. "J5 fixLots"). Env: DATABASE_URL.
import postgres from "postgres";

const sql = postgres(process.env.DATABASE_URL!, { max: 1, onnotice: () => {} });
const rows = await sql<{ family: string; status: string; n: number }[]>`
  select coalesce(split_part(job_key, ':', 1), '(none)') as family, status, count(*)::int as n
    from ops.keeper_tx group by 1, 2 order by 1, 2`;
const by = new Map<string, Record<string, number>>();
for (const r of rows) by.set(r.family, { ...(by.get(r.family) ?? {}), [r.status]: r.n });
const total: Record<string, number> = {};
console.log("keeper tx summary (ops.keeper_tx): job | mined | reverted | replaced | dropped | pending");
for (const [f, s] of by) {
  for (const [k, v] of Object.entries(s)) total[k] = (total[k] ?? 0) + v;
  console.log(`  ${f} | ${s.mined ?? 0} | ${s.reverted ?? 0} | ${s.replaced ?? 0} | ${s.dropped ?? 0} | ${s.pending ?? 0}`);
}
console.log(`  total | ${total.mined ?? 0} | ${total.reverted ?? 0} | ${total.replaced ?? 0} | ${total.dropped ?? 0} | ${total.pending ?? 0}`);
await sql.end();
