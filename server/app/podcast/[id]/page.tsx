import { cache } from "react";
import { siteUrl } from "@/lib/config";
import type { Metadata } from "next";
import { notFound } from "next/navigation";
import Link from "next/link";
import { getDatabase } from "@/lib/db/client";
import { ApiError } from "@/lib/http/errors";
import { publicPodcastData } from "@/lib/services/podcast-sharing";
import PodcastWebPlayer from "./player";

export const dynamic = "force-dynamic";
export const maxDuration = 180;
const loadPodcast = cache((id: string, language: string | null) => publicPodcastData(getDatabase(), id, language));
type Props = { params: Promise<{ id: string }>; searchParams: Promise<{ language?: string | string[] }> };
export async function generateMetadata({ params, searchParams }: Props): Promise<Metadata> {
  const { id } = await params;
  const { language } = await searchParams;
  try {
    const podcast = await loadPodcast(id, typeof language === "string" ? language : null);
    const url = `${siteUrl()}/podcast/${id}${podcast.coverPath.includes("?") ? podcast.coverPath.slice(podcast.coverPath.indexOf("?")) : ""}`;
    const description = podcast.article?.description ?? podcast.title;
    const images = [{ url: `${siteUrl()}${podcast.coverPath}`, width: 1200, height: 630, alt: podcast.title }];
    return { title: podcast.title, description, robots: { index: false, follow: false },
      openGraph: { type: "article", siteName: "Chippy", title: podcast.title, description, url, images },
      twitter: { card: "summary_large_image", title: podcast.title, description, images } };
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) notFound();
    throw error;
  }
}

export default async function PodcastPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ language?: string | string[] }> }) {
  const { id } = await params;
  const { language } = await searchParams;
  let podcast;
  try {
    podcast = await loadPodcast(id, typeof language === "string" ? language : null);
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) notFound();
    throw error;
  }
  return <main className="mx-auto flex min-h-dvh w-full max-w-7xl flex-col gap-6 px-5 py-8 sm:px-8">
    <Link href="/" className="text-sm font-semibold opacity-60">Chippy</Link>
    <PodcastWebPlayer key={podcast.language} podcast={podcast} />
  </main>;
}
