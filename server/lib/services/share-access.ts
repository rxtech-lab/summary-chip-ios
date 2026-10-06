import { and, eq, getTableName, or, sql, type SQL } from "drizzle-orm";
import type { AnySQLiteColumn } from "drizzle-orm/sqlite-core";
import type { Database } from "@/lib/db/client";
import { shareLinkEmails, shareLinks, summaries, users, type ShareLinkRow, type SummaryRow } from "@/lib/db/schema";
import { isPublicAndLive } from "./search";

/**
 * Who may open a summary besides its owner:
 * - anyone, through its own `slug` link, while it is public and that link has not expired;
 * - anyone holding a live extra share link (`share_links`), even while the summary is private;
 *   an `invited` link only lets in signed-in users whose email is on its list.
 * A signed-in viewer keeps access through the share link they opened (`summary_views.share_link_id`)
 * for as long as that link would still let them in: deleting the link or revoking their address ends it.
 */

/** True when anyone with the summary's own link may open it: public and the link has not expired. */
export function isLinkLive(row: Pick<SummaryRow, "visibility" | "expiresAt">, now = new Date()): boolean {
  return row.visibility === "public" && (row.expiresAt === null || row.expiresAt > now);
}

export function isShareLinkLive(link: Pick<ShareLinkRow, "expiresAt">, now = new Date()): boolean {
  return link.expiresAt === null || link.expiresAt > now;
}

/**
 * For the current `summaries` row: the token of the share link through which `viewerId` may still
 * open it, or NULL. Correlated on `summaries.id`, so it can be selected or filtered on. `viewerId`
 * may be a column (e.g. `summaryViews.userId`) to check every viewer of a summary at once.
 */
export function grantTokenSql(viewerId: string | AnySQLiteColumn, now = new Date()): SQL<string | null> {
  // Qualified by hand: drizzle leaves columns unqualified in single-table selects, which would bind inside the subquery.
  const summaryId = sql`${sql.identifier("summaries")}.${sql.identifier("id")}`;
  const viewer = typeof viewerId === "string" ? sql`${viewerId}` : sql`${sql.identifier(getTableName(viewerId.table))}.${sql.identifier(viewerId.name)}`;
  return sql<string | null>`(SELECT l.token FROM share_links l JOIN summary_views v ON v.share_link_id = l.id
    WHERE v.user_id = ${viewer} AND v.summary_id = ${summaryId} AND l.summary_id = v.summary_id
      AND (l.expires_at IS NULL OR l.expires_at > ${now.getTime()})
      AND (l.access = 'anyone' OR EXISTS (SELECT 1 FROM share_link_emails e JOIN users u ON u.id = v.user_id
        WHERE e.link_id = l.id AND e.email = lower(u.email)))
    LIMIT 1)`;
}

/** Summaries `viewerId` may open without owning them: a live public link, or a share link that still lets them in. */
export function readableByViewer(viewerId: string | AnySQLiteColumn, now = new Date()): SQL {
  return or(isPublicAndLive(now), sql`${grantTokenSql(viewerId, now)} IS NOT NULL`)!;
}

export async function findGrantToken(db: Database, summaryId: string, viewerId: string, now = new Date()): Promise<string | null> {
  const [row] = await db.select({ token: grantTokenSql(viewerId, now) }).from(summaries).where(eq(summaries.id, summaryId)).limit(1);
  return row?.token ?? null;
}

/** The owner always; anyone else while the public link is live or a share link still lets them in. */
export async function canViewerRead(db: Database, row: SummaryRow, viewerId: string | null, now = new Date()): Promise<boolean> {
  if (row.ownerId === viewerId || isLinkLive(row, now)) return true;
  return viewerId !== null && await findGrantToken(db, row.id, viewerId, now) !== null;
}

export interface ShareViewer {
  id: string;
  /** From the access token; falls back to the email on the user's row. */
  email?: string | null;
}

export type ShareKeyResolution =
  /** `link` is the share link it was opened with; null for the summary's own link. */
  | { status: "ok"; row: SummaryRow; link: ShareLinkRow | null }
  /** An invited-only link opened by someone signed out: they have to sign in first. */
  | { status: "sign-in"; link: ShareLinkRow }
  /** An invited-only link opened by a signed-in user whose email isn't on the list. */
  | { status: "not-invited"; link: ShareLinkRow }
  | { status: "missing" };

/**
 * What `/s/<key>` opens for `viewer`. `key` is a summary's `slug` or a share link's `token`. Missing,
 * private and expired all come back as `missing`, so a link never reveals that a summary exists.
 */
export async function resolveShareKey(db: Database, key: string, viewer: ShareViewer | null, now = new Date()): Promise<ShareKeyResolution> {
  const [bySlug] = await db.select().from(summaries).where(eq(summaries.slug, key)).limit(1);
  if (bySlug) {
    return await canViewerRead(db, bySlug, viewer?.id ?? null, now) ? { status: "ok", row: bySlug, link: null } : { status: "missing" };
  }
  const [found] = await db.select({ link: shareLinks, row: summaries }).from(shareLinks)
    .innerJoin(summaries, eq(summaries.id, shareLinks.summaryId))
    .where(eq(shareLinks.token, key)).limit(1);
  if (!found) return { status: "missing" };
  const { link, row } = found;
  if (row.ownerId === viewer?.id) return { status: "ok", row, link };
  if (!isShareLinkLive(link, now)) return { status: "missing" };
  if (link.access === "anyone") return { status: "ok", row, link };
  if (!viewer) return { status: "sign-in", link };
  return await isInvited(db, link.id, viewer) ? { status: "ok", row, link } : { status: "not-invited", link };
}

async function isInvited(db: Database, linkId: string, viewer: ShareViewer): Promise<boolean> {
  let email = viewer.email?.trim().toLowerCase();
  if (!email) {
    const [user] = await db.select({ email: users.email }).from(users).where(eq(users.id, viewer.id)).limit(1);
    email = user?.email?.trim().toLowerCase();
  }
  if (!email) return false;
  const [match] = await db.select({ email: shareLinkEmails.email }).from(shareLinkEmails)
    .where(and(eq(shareLinkEmails.linkId, linkId), eq(shareLinkEmails.email, email))).limit(1);
  return match !== undefined;
}
