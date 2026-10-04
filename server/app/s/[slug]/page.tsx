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
import { hostOf, siteNameFor } from "@/lib/extract";
import { runAfter } from "@/lib/http/after";
import { isValidSlug } from "@/lib/slug";
import { LANGUAGE_NAMES } from "@/lib/ai/summary-schema";
import { publicOgImageUrl, shareUrlFor } from "@/lib/services/serialize";
import { findPublicSummaryBySlug, incrementViewCount } from "@/lib/services/summaries";
import { preferredLanguage, readingLanguage, readSummary, translationLanguageFor } from "@/lib/services/translations";

/** Exported so Next allows a 300 s budget: the source translation continues after the response. */
export const maxDuration = 300;

type Props = { params: Promise<{ slug: string }>; searchParams: Promise<{ lang?: string | string[] }> };

const loadSummary = cache(async (slug: string): Promise<SummaryRow | undefined> => {
  if (!isValidSlug(slug)) return undefined;
  return findPublicSummaryBySlug(getDatabase(), slug);
});

/** What a visitor reads: the summary as written, or translated into their language. */
interface PageText {
  title: string;
  summary: string;
  highlights: string[];
  language: string;
  translated: boolean;
}

/**
 * The page opens in the visitor's language (`Accept-Language`), or `?lang=` (`original` for the
 * summary as written). Crawlers get it as written, so link previews match the shared card.
 */
const loadText = cache(async (slug: string, lang: string | undefined): Promise<PageText | undefined> => {
  const row = await loadSummary(slug);
  if (!row) return undefined;
  const original: PageText = { title: row.title, summary: row.summary, highlights: row.highlights, language: row.language, translated: false };
  const requestHeaders = await headers();
  if (lang === "original" || isBotUserAgent(requestHeaders.get("user-agent"))) return original;
  const wanted = lang ? translationLanguageFor(lang) : preferredLanguage(requestHeaders.get("accept-language"));
  const { translation } = await readSummary(getDatabase(), row, readingLanguage(row, null, wanted));
  if (!translation) return original;
  return { title: translation.title, summary: translation.summary, highlights: translation.highlights, language: translation.language, translated: true };
});

function languageName(code: string): string {
  const known = translationLanguageFor(code);
  return known ? LANGUAGE_NAMES[known] : code;
}

function firstValue(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

function appleItunesApp(): string {
  const appId = process.env.APP_STORE_ID?.trim();
  return [appId ? `app-id=${appId}` : null, `app-clip-bundle-id=${APP_CLIP_BUNDLE_ID}`, "app-clip-display=card"]
    .filter(Boolean)
    .join(", ");
}

export async function generateMetadata({ params, searchParams }: Props): Promise<Metadata> {
  const { slug } = await params;
  const row = await loadSummary(slug);
  const text = await loadText(slug, firstValue((await searchParams).lang));
  if (!row || !text) return { title: "Summary not found", robots: { index: false } };
  const shareUrl = shareUrlFor(row.slug);
  const image = { url: publicOgImageUrl(row), width: 1200, height: 630, alt: row.title, type: "image/png" };
  return {
    title: text.title,
    description: text.summary,
    alternates: { canonical: shareUrl },
    robots: { index: false, follow: true },
    openGraph: {
      type: "article",
      url: shareUrl,
      siteName: "Chippy",
      title: text.title,
      description: text.summary,
      images: [image],
      locale: text.language.replace("-", "_"),
      publishedTime: row.createdAt.toISOString(),
      ...(row.expiresAt ? { expirationTime: row.expiresAt.toISOString() } : {}),
      tags: row.tags,
    },
    twitter: {
      card: "summary_large_image",
      title: text.title,
      description: text.summary,
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

export default async function SummaryPage({ params, searchParams }: Props) {
  const { slug } = await params;
  const row = await loadSummary(slug);
  const text = await loadText(slug, firstValue((await searchParams).lang));
  if (!row || !text) notFound();

  const userAgent = (await headers()).get("user-agent");
  if (!isBotUserAgent(userAgent)) runAfter(() => incrementViewCount(getDatabase(), row.id));

  const { colors, accent, emoji } = row.theme;
  const accentText = luminance(accent) > 0.45 ? "#0f172a" : "#ffffff";
  const site = siteNameFor(row.siteName ?? hostOf(row.sourceUrl), row.sourceUrl);
  const href = originalHref(row);
  const gradient = `linear-gradient(135deg, ${colors.join(", ")})`;

  return (
    <main className="relative min-h-dvh overflow-hidden">
      <div aria-hidden className="pointer-events-none absolute inset-x-0 top-0 h-[420px] opacity-25 blur-3xl" style={{ backgroundImage: gradient }} />
      <article lang={text.language} className="relative mx-auto max-w-3xl px-5 pb-16 pt-8 sm:px-8 sm:pt-14">
        <header className="flex items-center justify-between text-sm">
          <Link href="/" className="md-brand-link text-lg font-semibold">Chippy</Link>
          <span className="text-slate-500">{formatDate(row.createdAt)}</span>
        </header>

        <div className="md-card mt-6 overflow-hidden" style={{ backgroundImage: gradient }}>
          {/* eslint-disable-next-line @next/next/no-img-element -- served from our own route with its own caching */}
          <img src={publicOgImageUrl(row)} alt={text.title} width={1200} height={630} className="block aspect-[1200/630] w-full object-cover" />
        </div>

        <div className="mt-8 flex flex-wrap items-center gap-3">
          <span className="text-2xl" aria-hidden>{emoji}</span>
          <span className="rounded-full px-3 py-1 text-xs font-semibold uppercase tracking-wider" style={{ backgroundColor: accent, color: accentText }}>
            {row.category}
          </span>
          {site ? <span className="text-sm text-slate-500">{site}</span> : null}
        </div>

        <h1 className="mt-4 text-3xl font-normal leading-tight tracking-tight sm:text-4xl">{text.title}</h1>
        <p className="md-text-secondary mt-5 text-lg leading-relaxed">{text.summary}</p>
        {text.translated ? (
          <p className="mt-3 text-sm text-slate-500">
            Translated from {languageName(row.language)} by Chippy · <Link href={`/s/${row.slug}?lang=original`} className="font-semibold text-slate-700 hover:underline">Show original</Link>
          </p>
        ) : null}

        {text.highlights.length ? (
          <section className="mt-10">
            <h2 className="text-sm font-semibold uppercase tracking-wider text-slate-500">Highlights</h2>
            <ul className="mt-4 space-y-3">
              {text.highlights.map((highlight, index) => (
                <li key={index} className="md-card-outlined flex gap-3 p-4 leading-relaxed">
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
              <li key={tag} className="md-chip">#{tag}</li>
            ))}
          </ul>
        ) : null}

        {href ? (
          <a
            href={href}
            target="_blank"
            rel="noopener noreferrer nofollow"
            className="md-button mt-10"
            style={{ backgroundColor: accent, color: accentText }}
          >
            Read the original
            <span aria-hidden>↗</span>
          </a>
        ) : null}

        <footer className="mt-14 border-t border-slate-200 pt-6 text-sm text-slate-500">
          <p>
            Summarised by <Link href="/" className="font-semibold text-slate-700 hover:underline">Chippy</Link>
            {row.sourceTitle && row.sourceTitle !== row.title && row.sourceTitle !== text.title ? <> from “{row.sourceTitle}”</> : null}. AI summaries can contain mistakes — check the original.
          </p>
          <p className="mt-2">
            {row.expiresAt ? <>This link expires on <time dateTime={row.expiresAt.toISOString()}>{formatDate(row.expiresAt)}</time>.</> : "This link does not expire."}
          </p>
        </footer>
      </article>
    </main>
  );
}
