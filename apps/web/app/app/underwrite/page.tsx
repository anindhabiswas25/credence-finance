import type { Metadata } from "next";
import { UnderwriteView } from "@/components/app/views/UnderwriteView";

export const metadata: Metadata = { title: "Underwrite" };

export default async function UnderwritePage({ searchParams }: { searchParams: Promise<{ stack?: string }> }) {
  const { stack } = await searchParams;
  return <UnderwriteView stack={stack === "nav" ? "nav" : "equity"} />;
}
