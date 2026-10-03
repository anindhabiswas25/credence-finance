import type { Metadata } from "next";
import { AuctionsView } from "@/components/app/views/AuctionsView";

export const metadata: Metadata = { title: "Auctions" };

export default function AuctionsPage() {
  return <AuctionsView />;
}
