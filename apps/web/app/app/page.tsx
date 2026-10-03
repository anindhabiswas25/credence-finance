import type { Metadata } from "next";
import { OverviewView } from "@/components/app/views/OverviewView";

export const metadata: Metadata = { title: "Overview" };

/** Overview: the hero dashboard, live. */
export default function OverviewPage() {
  return <OverviewView />;
}
