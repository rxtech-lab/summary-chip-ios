import type { Metadata } from "next";
import { SiteHeader } from "@/components/site-header";
import { getDatabase } from "@/lib/db/client";
import { listedAuthorName } from "@/lib/services/marketplace";
import DiscoverFeed from "./discover-feed";

type Props = { searchParams: Promise<{ author?: string | string[] }> };

export async function generateMetadata({ searchParams }: Props): Promise<Metadata> {
  const { author } = await searchParams;
  const name = typeof author === "string" ? await listedAuthorName(getDatabase(), author) : null;
  const query = name ? `?author=${encodeURIComponent(author as string)}` : "";
  const title = name ? `${name} on Discover` : "Discover";
  const description = name
    ? `Summaries, podcasts and more published by ${name} on Chippy.`
    : "Discover something worth keeping: summaries, podcasts and more, published by the Chippy community.";
  const image = { url: `/discover/og.png${query}`, width: 1200, height: 630, alt: `${title} · Chippy` };
  return {
    title,
    description,
    alternates: { canonical: `/discover${query}` },
    openGraph: { type: "website", siteName: "Chippy", url: `/discover${query}`, title: `${title} · Chippy`, description, images: [image] },
    twitter: { card: "summary_large_image", title: `${title} · Chippy`, description, images: [image] },
  };
}

export default function Discover() {
  return <><SiteHeader discover /><div className="pt-24"><DiscoverFeed /></div></>;
}
