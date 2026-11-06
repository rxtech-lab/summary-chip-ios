import { and, desc, eq, gt, isNull, or } from "drizzle-orm";
import { fetchUserInfoName } from "@/lib/auth/userinfo";
import type { Database } from "@/lib/db/client";
import { marketplacePublications, summaries, users, type SummaryRow } from "@/lib/db/schema";
import { toSummaryJson } from "./serialize";

const PAGE_SIZE = 50;

type ListedRow = { row: SummaryRow; authorId: string; authorName: string | null; publishedAt: Date };

/** `chip` is the whole summary as `viewerId` sees it, so apps can draw their regular feed card. */
function toItem({ row, authorId, authorName, publishedAt }: ListedRow, viewerId: string | null) {
  return { id: row.id, title: row.title, summary: row.summary, kind: row.kind, slug: row.slug, authorId, authorName,
    publishedAt: publishedAt.toISOString(), chip: toSummaryJson(row, viewerId) };
}

function listedRows(db: Database) {
  return db.select({ row: summaries, authorId: users.id, authorName: users.name, publishedAt: marketplacePublications.publishedAt })
    .from(marketplacePublications).innerJoin(summaries, eq(summaries.id, marketplacePublications.summaryId))
    .innerJoin(users, eq(users.id, summaries.ownerId));
}

/** What Discover shows anyone: public, unexpired publications by accounts not being deleted. */
function isListed(author?: string) {
  return and(eq(summaries.visibility, "public"), or(isNull(summaries.expiresAt), gt(summaries.expiresAt, new Date())),
    isNull(users.deletionScheduledAt), author ? eq(users.id, author) : undefined);
}

export async function listMarketplace(db: Database, author?: string, offset = 0) {
  const rows = await listedRows(db).where(isListed(author))
    .orderBy(desc(marketplacePublications.publishedAt), desc(summaries.id)).limit(PAGE_SIZE).offset(offset);
  return rows.map(row => toItem(row, null));
}

/** The byline for an author with listed content; null otherwise, so a user id alone cannot reveal a name. */
export async function listedAuthorName(db: Database, authorId: string): Promise<string | null> {
  const [author] = await db.select({ name: users.name }).from(marketplacePublications)
    .innerJoin(summaries, eq(summaries.id, marketplacePublications.summaryId))
    .innerJoin(users, eq(users.id, summaries.ownerId))
    .where(isListed(authorId)).limit(1);
  return author ? author.name || "Chippy author" : null;
}

/** Everything the owner has published, including chips Discover hides because they went private or expired. */
export async function listOwnPublications(db: Database, ownerId: string, offset = 0) {
  const rows = await listedRows(db).where(eq(summaries.ownerId, ownerId))
    .orderBy(desc(marketplacePublications.publishedAt), desc(summaries.id)).limit(PAGE_SIZE).offset(offset);
  return rows.map(row => toItem(row, ownerId));
}

/** Access tokens carry no name, so an author's byline comes from the identity provider. Never fails the caller. */
export async function refreshAuthorName(db: Database, userId: string, authorization: string): Promise<void> {
  const name = await fetchUserInfoName(authorization);
  if (name) await db.update(users).set({ name }).where(eq(users.id, userId));
}
