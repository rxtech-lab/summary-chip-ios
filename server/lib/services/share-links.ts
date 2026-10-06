import { and, asc, count, eq, inArray, notInArray } from "drizzle-orm";
import { defaultTtlDays, expiresAtFor } from "@/lib/config";
import { MAX_SHARE_LINKS, type CreateShareLinkInput, type PatchShareLinkInput } from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { shareLinkEmails, shareLinks, summaries, type ShareLinkAccess, type ShareLinkRow } from "@/lib/db/schema";
import { ApiError, notFound } from "@/lib/http/errors";
import { generateSlug } from "@/lib/slug";
import { shareUrlFor } from "./serialize";
import { isShareLinkLive } from "./share-access";
import { getOwnedSummary } from "./summaries";

/** An extra share link as its owner manages it. */
export interface ShareLinkJson {
  id: string;
  url: string;
  label: string | null;
  access: ShareLinkAccess;
  ttlDays: number | null;
  expiresAt: string | null;
  isExpired: boolean;
  emails: { email: string; addedAt: string }[];
  createdAt: string;
  updatedAt: string;
}

type EmailRow = { email: string; addedAt: Date };

function toShareLinkJson(link: ShareLinkRow, emails: EmailRow[], now = new Date()): ShareLinkJson {
  return {
    id: link.id,
    url: shareUrlFor(link.token),
    label: link.label,
    access: link.access,
    ttlDays: link.ttlDays,
    expiresAt: link.expiresAt ? link.expiresAt.toISOString() : null,
    isExpired: !isShareLinkLive(link, now),
    emails: emails.map((entry) => ({ email: entry.email, addedAt: entry.addedAt.toISOString() })),
    createdAt: link.createdAt.toISOString(),
    updatedAt: link.updatedAt.toISOString(),
  };
}

async function emailsOf(db: Database, linkIds: string[]): Promise<Map<string, EmailRow[]>> {
  const byLink = new Map<string, EmailRow[]>();
  if (!linkIds.length) return byLink;
  const rows = await db.select().from(shareLinkEmails).where(inArray(shareLinkEmails.linkId, linkIds))
    .orderBy(asc(shareLinkEmails.addedAt), asc(shareLinkEmails.email));
  for (const row of rows) byLink.set(row.linkId, [...byLink.get(row.linkId) ?? [], row]);
  return byLink;
}

async function readLink(db: Database, link: ShareLinkRow, now: Date): Promise<ShareLinkJson> {
  return toShareLinkJson(link, (await emailsOf(db, [link.id])).get(link.id) ?? [], now);
}

async function getOwnedLink(db: Database, ownerId: string, summaryId: string, linkId: string): Promise<ShareLinkRow> {
  await getOwnedSummary(db, summaryId, ownerId);
  const [link] = await db.select().from(shareLinks)
    .where(and(eq(shareLinks.id, linkId), eq(shareLinks.summaryId, summaryId))).limit(1);
  if (!link) throw notFound("The share link does not exist");
  return link;
}

/** A token unused by any summary slug or other link (both open at `/s/<key>`). */
async function freshToken(db: Database): Promise<string> {
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const token = generateSlug(12);
    const [slug] = await db.select({ id: summaries.id }).from(summaries).where(eq(summaries.slug, token)).limit(1);
    const [link] = await db.select({ id: shareLinks.id }).from(shareLinks).where(eq(shareLinks.token, token)).limit(1);
    if (!slug && !link) return token;
  }
  throw new ApiError(500, "TOKEN_COLLISION", "Could not create a share link, try again");
}

/** The summary's extra share links, oldest first. Owner only. */
export async function listShareLinks(db: Database, ownerId: string, summaryId: string, now = new Date()): Promise<{ items: ShareLinkJson[] }> {
  await getOwnedSummary(db, summaryId, ownerId);
  const links = await db.select().from(shareLinks).where(eq(shareLinks.summaryId, summaryId))
    .orderBy(asc(shareLinks.createdAt), asc(shareLinks.id));
  const emails = await emailsOf(db, links.map((link) => link.id));
  return { items: links.map((link) => toShareLinkJson(link, emails.get(link.id) ?? [], now)) };
}

export async function createShareLink(db: Database, ownerId: string, summaryId: string, input: CreateShareLinkInput, now = new Date()): Promise<ShareLinkJson> {
  await getOwnedSummary(db, summaryId, ownerId);
  const [{ total }] = await db.select({ total: count() }).from(shareLinks).where(eq(shareLinks.summaryId, summaryId));
  if (total >= MAX_SHARE_LINKS) {
    throw new ApiError(409, "TOO_MANY_SHARE_LINKS", `A summary can have at most ${MAX_SHARE_LINKS} share links`);
  }
  const ttlDays = input.ttlDays === undefined ? defaultTtlDays() : input.ttlDays;
  const link: ShareLinkRow = {
    id: crypto.randomUUID(),
    summaryId,
    token: await freshToken(db),
    label: input.label ?? null,
    access: input.access,
    ttlDays,
    expiresAt: expiresAtFor(ttlDays, now),
    createdAt: now,
    updatedAt: now,
  };
  const emails = input.emails.map((email) => ({ linkId: link.id, email, addedAt: now }));
  await db.batch([
    db.insert(shareLinks).values(link),
    ...(emails.length ? [db.insert(shareLinkEmails).values(emails)] : []),
  ] as unknown as Parameters<typeof db.batch>[0]);
  return toShareLinkJson(link, emails, now);
}

/**
 * Changes a link. `emails` replaces the invited list (addresses already on it keep their date);
 * revoking an address ends that person's access at once. A new `ttlDays` restarts the lifetime.
 */
export async function patchShareLink(
  db: Database,
  ownerId: string,
  summaryId: string,
  linkId: string,
  patch: PatchShareLinkInput,
  now = new Date(),
): Promise<ShareLinkJson> {
  const existing = await getOwnedLink(db, ownerId, summaryId, linkId);
  const changes: Partial<ShareLinkRow> = { updatedAt: now };
  if (patch.label !== undefined) changes.label = patch.label;
  if (patch.access !== undefined) changes.access = patch.access;
  if (patch.ttlDays !== undefined) {
    changes.ttlDays = patch.ttlDays;
    changes.expiresAt = expiresAtFor(patch.ttlDays, now);
  }
  const access = changes.access ?? existing.access;
  if (access === "invited") {
    const remaining = patch.emails ?? ((await emailsOf(db, [linkId])).get(linkId) ?? []).map((entry) => entry.email);
    if (!remaining.length) throw new ApiError(400, "VALIDATION_ERROR", "An invited link needs at least one email");
  }
  const emails = patch.emails;
  await db.batch([
    db.update(shareLinks).set(changes).where(eq(shareLinks.id, linkId)),
    ...(emails !== undefined ? [
      emails.length
        ? db.delete(shareLinkEmails).where(and(eq(shareLinkEmails.linkId, linkId), notInArray(shareLinkEmails.email, emails)))
        : db.delete(shareLinkEmails).where(eq(shareLinkEmails.linkId, linkId)),
      ...(emails.length ? [db.insert(shareLinkEmails).values(emails.map((email) => ({ linkId, email, addedAt: now }))).onConflictDoNothing()] : []),
    ] : []),
  ] as unknown as Parameters<typeof db.batch>[0]);
  return readLink(db, { ...existing, ...changes }, now);
}

/** Deletes a link: it stops opening, and everyone who opened the summary through it loses access. */
export async function deleteShareLink(db: Database, ownerId: string, summaryId: string, linkId: string): Promise<void> {
  await getOwnedLink(db, ownerId, summaryId, linkId);
  await db.delete(shareLinks).where(eq(shareLinks.id, linkId));
}
