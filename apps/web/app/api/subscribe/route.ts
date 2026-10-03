import { NextResponse } from "next/server";

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/**
 * Newsletter / "Open Account" sign-ups from the landing page.
 *
 * TODO: nothing stores these yet. Wire this to the API service (or an email provider) before
 * launch; until then a valid address is accepted and dropped.
 */
export async function POST(req: Request) {
  const body = (await req.json().catch(() => null)) as { email?: unknown; source?: unknown } | null;
  const email = typeof body?.email === "string" ? body.email.trim() : "";
  if (email.length > 256 || !EMAIL.test(email)) {
    return NextResponse.json({ error: "invalid email" }, { status: 400 });
  }
  return new NextResponse(null, { status: 202 });
}
