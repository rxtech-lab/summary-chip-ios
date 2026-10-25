import { podcastArticle, podcastCover } from "./podcast-publication";
import { and, asc, count, eq } from "drizzle-orm";
import { defaultTtlDays, expiresAtFor, siteUrl } from "@/lib/config";
import { MAX_SHARE_LINKS } from "@/lib/contracts/api";
import type { CreatePodcastShareLinkInput, PatchPodcastShareLinkInput, PodcastDay } from "@/lib/contracts/daily-podcast";
import type { Database } from "@/lib/db/client";
import { podcastShareLinks, summaries, type PodcastShareLinkRow } from "@/lib/db/schema";
import { ApiError, notFound } from "@/lib/http/errors";
import { generateSlug, isValidSlug } from "@/lib/slug";
import { dailyPodcastEpisode, podcastInLanguage } from "./daily-podcast";
import { isLinkLive, isShareLinkLive } from "./share-access";

/**
 * A podcast share link as its owner manages it. Same shape as a chip's share link so the apps
 * reuse one model; podcast links always open for anyone holding them (the web player is signed out).
 */
export interface PodcastShareLinkJson {
  id: string;
  url: string;
  label: string | null;
  access: "anyone";
  ttlDays: number | null;
  expiresAt: string | null;
  isExpired: boolean;
  emails: never[];
  createdAt: string;
  updatedAt: string;
}

export const podcastShareUrlFor = (token: string) => `${siteUrl()}/podcast/${token}`;

function toJson(link: PodcastShareLinkRow, now = new Date()): PodcastShareLinkJson {
  return {
    id: link.id,
    url: podcastShareUrlFor(link.token),
    label: link.label,
    access: "anyone",
    ttlDays: link.ttlDays,
    expiresAt: link.expiresAt ? link.expiresAt.toISOString() : null,
    isExpired: !isShareLinkLive(link, now),
    emails: [],
    createdAt: link.createdAt.toISOString(),
    updatedAt: link.updatedAt.toISOString(),
  };
}

const ownerEpisode = (ownerId: string, key: string) => and(eq(podcastShareLinks.ownerId, ownerId), eq(podcastShareLinks.episodeKey, key));

async function getOwnedLink(db: Database, ownerId: string, key: string, linkId: string): Promise<PodcastShareLinkRow> {
  const [link] = await db.select().from(podcastShareLinks)
    .where(and(ownerEpisode(ownerId, key), eq(podcastShareLinks.id, linkId))).limit(1);
  if (!link) throw notFound("The share link does not exist");
  return link;
}

async function freshToken(db: Database): Promise<string> {
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const token = generateSlug(12);
    const [taken] = await db.select({ id: podcastShareLinks.id }).from(podcastShareLinks).where(eq(podcastShareLinks.token, token)).limit(1);
    if (!taken) return token;
  }
  throw new ApiError(500, "TOKEN_COLLISION", "Could not create a share link, try again");
}

async function publishableEpisode(db: Database, ownerId: string, day: PodcastDay, key: string) {
  const podcast = await dailyPodcastEpisode(db, ownerId, day, key);
  // An invited chip grants reading rights, not permission to republish its contents publicly.
  for (const id of podcast.chipIds) {
    const [chip] = await db.select().from(summaries).where(eq(summaries.id, id)).limit(1);
    if (!chip || (chip.ownerId !== ownerId && !isLinkLive(chip))) {
      throw new ApiError(403, "PODCAST_SOURCE_PRIVATE", "This episode includes someone else's private chip. Regenerate it without that chip before sharing.");
    }
  }
  return podcast;
}

/** The episode's share links, oldest first. Listing and deleting stay possible after a source becomes unavailable. */
export async function listPodcastShareLinks(db: Database, ownerId: string, key: string, now = new Date()): Promise<{ items: PodcastShareLinkJson[] }> {
  const links = await db.select().from(podcastShareLinks).where(ownerEpisode(ownerId, key))
    .orderBy(asc(podcastShareLinks.createdAt), asc(podcastShareLinks.id));
  return { items: links.map((link) => toJson(link, now)) };
}

export async function createPodcastShareLink(db: Database, ownerId: string, key: string, input: CreatePodcastShareLinkInput, now = new Date()): Promise<PodcastShareLinkJson> {
  const episode = await publishableEpisode(db, ownerId, input.day, key);
  const [{ total }] = await db.select({ total: count() }).from(podcastShareLinks).where(ownerEpisode(ownerId, key));
  if (total >= MAX_SHARE_LINKS) {
    throw new ApiError(409, "TOO_MANY_SHARE_LINKS", `A podcast can have at most ${MAX_SHARE_LINKS} share links`);
  }
  const ttlDays = input.ttlDays === undefined ? defaultTtlDays() : input.ttlDays;
  const link: PodcastShareLinkRow = {
    id: crypto.randomUUID(),
    ownerId,
    episodeKey: key,
    day: input.day,
    token: await freshToken(db),
    label: input.label ?? null,
    ttlDays,
    expiresAt: expiresAtFor(ttlDays, now),
    createdAt: now,
    updatedAt: now,
  };
  // Finish the original language's preview before returning a newly published URL.
  await Promise.all([podcastArticle(episode), podcastCover(episode)]);
  await db.insert(podcastShareLinks).values(link);
  return toJson(link, now);
}

/** Renames a link or, with a new `ttlDays`, restarts its lifetime from now. */
export async function patchPodcastShareLink(
  db: Database, ownerId: string, key: string, linkId: string, patch: PatchPodcastShareLinkInput, now = new Date(),
): Promise<PodcastShareLinkJson> {
  const existing = await getOwnedLink(db, ownerId, key, linkId);
  const changes: Partial<PodcastShareLinkRow> = { updatedAt: now };
  if (patch.label !== undefined) changes.label = patch.label;
  if (patch.ttlDays !== undefined) {
    changes.ttlDays = patch.ttlDays;
    changes.expiresAt = expiresAtFor(patch.ttlDays, now);
  }
  await db.update(podcastShareLinks).set(changes).where(eq(podcastShareLinks.id, linkId));
  return toJson({ ...existing, ...changes }, now);
}

/** Deletes a link: it stops opening at once. */
export async function deletePodcastShareLink(db: Database, ownerId: string, key: string, linkId: string): Promise<void> {
  await getOwnedLink(db, ownerId, key, linkId);
  await db.delete(podcastShareLinks).where(eq(podcastShareLinks.id, linkId));
}

/**
 * Every page, media and artwork request passes this gate; no public bucket URLs are exposed.
 * `podcast` is presented in `language` when the episode has that translation, otherwise in its original language.
 */
export async function publicPodcast(db: Database, token: string, now = new Date(), language?: string | null) {
  const [link] = isValidSlug(token)
    ? await db.select().from(podcastShareLinks).where(eq(podcastShareLinks.token, token)).limit(1)
    : [];
  if (!link || !isShareLinkLive(link, now)) throw notFound("Podcast not found");
  try {
    const episode = await publishableEpisode(db, link.ownerId, link.day, link.episodeKey);
    const podcast = podcastInLanguage(episode, language && episode.translations?.[language] ? language : undefined);
    return { link, podcast };
  } catch (error) {
    if (error instanceof ApiError && [403, 404].includes(error.status)) throw notFound("Podcast not found");
    throw error;
  }
}

export async function publicPodcastData(db: Database, token: string, language?: string | null) {
  const { podcast } = await publicPodcast(db, token, undefined, language);
  // Media follow the listener's language; the original keeps the plain URLs.
  const suffix = podcast.language === podcast.originalLanguage ? "" : `?language=${encodeURIComponent(podcast.language)}`;
  // Older published episodes acquire the same persisted article on their first visit.
  const article = await podcastArticle(podcast).catch(error => {
    console.warn("[podcast] companion article unavailable", error);
    return null;
  });
  return { article: article ? { ...article, sections: article.sections.map(section => ({ ...section,
    startSeconds: podcast.segments[section.segmentIndex]?.startSeconds ?? 0 })) } : null,
    coverPath: `/api/public/podcasts/${token}/cover${suffix}`,
    title: podcast.title, language: podcast.language, languages: podcast.languages ?? [podcast.language], createdAt: podcast.createdAt,
    durationSeconds: podcast.durationSeconds, audioPath: `/api/public/podcasts/${token}/audio${suffix}`,
    videoPath: podcast.video?.published && podcast.video.published.videoId === podcast.video.id ? `/api/public/podcasts/${token}/video${suffix}` : null,
    segments: podcast.segments.map((segment, index) => ({ caption: segment.caption, captionCues: segment.captionCues,
      speaker: podcast.speakers[segment.speaker].name, startSeconds: segment.startSeconds ?? 0,
      endSeconds: segment.endSeconds ?? 0, icon: segment.icon,
      imagePath: segment.imagePath ? `/api/public/podcasts/${token}/art/${index}` : null })) };
}
