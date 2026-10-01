import type { Metadata } from "next";
import { headers } from "next/headers";
import Link from "next/link";
import { notFound } from "next/navigation";
import { cache } from "react";
import { luminance } from "@/lib/ai/summary-schema";
import { isBotUserAgent } from "@/lib/bots";
import { APP_CLIP_BUNDLE_ID } from "@/lib/config";
import { getDatabase } from "@/lib/db/client";
import type { SummaryRow } from "@/lib/db/schema";
import { hostOf } from "@/lib/extract";
import { runAfter } from "@/lib/http/after";
import { isValidSlug } from "@/lib/slug";
import { publicOgImageUrl, shareUrlFor } from "@/lib/services/serialize";
import { findPublicSummaryBySlug, incrementViewCount } from "@/lib/services/summaries";

type Props = { params: Promise<{ slug: string }> };

const loadSummary = cache(async (slug: string): Promise<SummaryRow | undefined> => {
  if (!isValidSlug(slug)) return undefined;
  return findPublicSummaryBySlug(getDatabase(), slug);
});

function appleItunesApp(): string {
  const appId = process.env.APP_STORE_ID?.trim();
  return [appId ? `app-id=${appId}` : null, `app-clip-bundle-id=${APP_CLIP_BUNDLE_ID}`, "app-clip-display=card"]
    .filter(Boolean)
    .join(", ");
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { slug } = await params;
  const row = await loadSummary(slug);
  if (!row) return { title: "Summary not found", robots: { index: false } };
  const shareUrl = shareUrlFor(row.slug);
  const image = { url: publicOgImageUrl(row), width: 1200, height: 630, alt: row.title, type: "image/png" };
  return {
    title: row.title,
    description: row.summary,
    alternates: { canonical: shareUrl },
    robots: { index: false, follow: true },
    openGraph: {
      type: "article",
      url: shareUrl,
      siteName: "Chippy",
      title: row.title,
      description: row.summary,
      images: [image],
      locale: row.language.replace("-", "_"),
      publishedTime: row.createdAt.toISOString(),
      ...(row.expiresAt ? { expirationTime: row.expiresAt.toISOString() } : {}),
      tags: row.tags,
    },
    twitter: {
      card: "summary_large_image",
      title: row.title,
      description: row.summary,
      images: [image],
    },
    other: { "apple-itunes-app": appleItunesApp() },
  };
}

function formatDate(date: Date): string {
  return date.toLocaleDateString("en-US", { dateStyle: "medium", timeZone: "UTC" });
}

function originalHref(row: SummaryRow): string | null {
  if (row.sourceType === "pdf" && row.sourceFileKey) return `/s/${row.slug}/source`;
  return row.sourceUrl;
}

export default async function SummaryPage({ params }: Props) {
  const { slug } = await params;
  const row = await loadSummary(slug);
  if (!row) notFound();

  const userAgent = (await headers()).get("user-agent");
  if (!isBotUserAgent(userAgent)) runAfter(() => incrementViewCount(getDatabase(), row.id));

  const { colors, accent, emoji } = row.theme;
  const accentText = luminance(accent) > 0.45 ? "#0f172a" : "#ffffff";
  const site = row.siteName ?? hostOf(row.sourceUrl);
  const href = originalHref(row);
  const gradient = `linear-gradient(135deg, ${colors.join(", ")})`;

  return (
    <main className="relative min-h-dvh overflow-hidden">
      <div aria-hidden className="pointer-events-none absolute inset-x-0 top-0 h-[420px] opacity-25 blur-3xl dark:opacity-30" style={{ backgroundImage: gradient }} />
      <article lang={row.language} className="relative mx-auto max-w-3xl px-5 pb-16 pt-8 sm:px-8 sm:pt-14">
        <header className="flex items-center justify-between text-sm">
          <Link href="/" className="font-semibold tracking-wide text-slate-700 hover:underline dark:text-slate-300">Chippy</Link>
          <span className="text-slate-500 dark:text-slate-400">{formatDate(row.createdAt)}</span>
        </header>

        <div className="mt-6 overflow-hidden rounded-3xl shadow-xl ring-1 ring-black/5 dark:ring-white/10" style={{ backgroundImage: gradient }}>
          {/* eslint-disable-next-line @next/next/no-img-element -- served from our own route with its own caching */}
          <img src={publicOgImageUrl(row)} alt={row.title} width={1200} height={630} className="block aspect-[1200/630] w-full object-cover" />
        </div>

        <div className="mt-8 flex flex-wrap items-center gap-3">
          <span className="text-2xl" aria-hidden>{emoji}</span>
          <span className="rounded-full px-3 py-1 text-xs font-semibold uppercase tracking-wider" style={{ backgroundColor: accent, color: accentText }}>
            {row.category}
          </span>
          {site ? <span className="text-sm text-slate-500 dark:text-slate-400">{site}</span> : null}
        </div>

        <h1 className="mt-4 text-3xl font-bold leading-tight tracking-tight sm:text-4xl">{row.title}</h1>
        <p className="mt-5 text-lg leading-relaxed text-slate-700 dark:text-slate-300">{row.summary}</p>

        {row.highlights.length ? (
          <section className="mt-10">
            <h2 className="text-sm font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">Highlights</h2>
            <ul className="mt-4 space-y-3">
              {row.highlights.map((highlight, index) => (
                <li key={index} className="flex gap-3 rounded-2xl bg-slate-50 p-4 leading-relaxed dark:bg-white/5">
                  <span className="mt-2 h-2 w-2 flex-none rounded-full" style={{ backgroundColor: accent }} aria-hidden />
                  <span>{highlight}</span>
                </li>
              ))}
            </ul>
          </section>
        ) : null}

        {row.tags.length ? (
          <ul className="mt-8 flex flex-wrap gap-2" aria-label="Tags">
            {row.tags.map((tag) => (
              <li key={tag} className="rounded-full border border-slate-200 px-3 py-1 text-sm text-slate-600 dark:border-slate-700 dark:text-slate-300">#{tag}</li>
            ))}
          </ul>
        ) : null}

        {href ? (
          <a
            href={href}
            target="_blank"
            rel="noopener noreferrer nofollow"
            className="mt-10 inline-flex items-center gap-2 rounded-full px-6 py-3 font-semibold shadow-lg transition hover:opacity-90 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
            style={{ backgroundColor: accent, color: accentText }}
          >
            Read the original
            <span aria-hidden>↗</span>
          </a>
        ) : null}

        <footer className="mt-14 border-t border-slate-200 pt-6 text-sm text-slate-500 dark:border-slate-800 dark:text-slate-400">
          <p>
            Summarised by <Link href="/" className="font-semibold text-slate-700 hover:underline dark:text-slate-200">Chippy</Link>
            {row.sourceTitle && row.sourceTitle !== row.title ? <> from “{row.sourceTitle}”</> : null}. AI summaries can contain mistakes — check the original.
          </p>
          <p className="mt-2">
            {row.expiresAt ? <>This link expires on <time dateTime={row.expiresAt.toISOString()}>{formatDate(row.expiresAt)}</time>.</> : "This link does not expire."}
          </p>
        </footer>
      </article>
    </main>
  );
}
