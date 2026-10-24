import type { Metadata } from "next";
import { notFound } from "next/navigation";
import Link from "next/link";
import { getDatabase } from "@/lib/db/client";
import { ApiError } from "@/lib/http/errors";
import { publicPodcastData } from "@/lib/services/podcast-sharing";
import PodcastWebPlayer from "./player";

export const dynamic = "force-dynamic";
export const metadata: Metadata = { title: "Podcast · Chippy", robots: { index: false, follow: false } };

export default async function PodcastPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ language?: string | string[] }> }) {
  const { id } = await params;
  const { language } = await searchParams;
  let podcast;
  try {
    podcast = await publicPodcastData(getDatabase(), id, typeof language === "string" ? language : null);
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) notFound();
    throw error;
  }
  return <main className="mx-auto flex min-h-dvh max-w-3xl flex-col justify-center gap-6 px-5 py-10">
    <Link href="/" className="text-sm font-semibold opacity-60">Chippy</Link>
    <PodcastWebPlayer key={podcast.language} podcast={podcast} />
  </main>;
}
