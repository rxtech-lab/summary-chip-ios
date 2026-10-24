import type { Metadata } from "next";
import { notFound } from "next/navigation";
import Link from "next/link";
import { getDatabase } from "@/lib/db/client";
import { ApiError } from "@/lib/http/errors";
import { publicPodcastData } from "@/lib/services/podcast-sharing";
import PodcastWebPlayer from "./player";

export const dynamic = "force-dynamic";
export const metadata: Metadata = { title: "Podcast · Chippy", robots: { index: false, follow: false } };

export default async function PodcastPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  let podcast;
  try {
    podcast = await publicPodcastData(getDatabase(), id);
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) notFound();
    throw error;
  }
  return <main className="mx-auto flex min-h-dvh max-w-3xl flex-col justify-center gap-6 px-5 py-10">
    <Link href="/" className="text-sm font-semibold opacity-60">Chippy</Link>
    <PodcastWebPlayer podcast={podcast} />
  </main>;
}
