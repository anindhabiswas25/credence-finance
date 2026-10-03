import type { Metadata } from "next";
import { LendView } from "@/components/app/views/LendView";

export const metadata: Metadata = { title: "Lend" };

export default async function LendPage({ searchParams }: { searchParams: Promise<{ stack?: string }> }) {
  const { stack } = await searchParams;
  return <LendView stack={stack === "nav" ? "nav" : "equity"} />;
}
