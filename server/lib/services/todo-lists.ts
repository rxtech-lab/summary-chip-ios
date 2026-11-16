import { runAfter } from "@/lib/http/after";
import { deliverTodoNotifications } from "./todo-notifications";
import { and, desc, eq, sql } from "drizzle-orm";
import type { ApiPrincipal } from "@/lib/auth/bearer";
import { todoDocumentSchema, type TodoDocument } from "@/lib/contracts/todo";
import type { Database } from "@/lib/db/client";
import { summaries, summaryTranslations, todoLists, type SummaryRow, type Visibility, type VersionActor } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { getObjectStore } from "@/lib/storage/r2";
import { versionStatements } from "./document-versions";
import { shareUrlFor } from "./serialize";
import { canViewerRead } from "./share-access";
import { findSummaryById, getOwnedSummary, insertSummary } from "./summaries";

export function todoDigest(document: TodoDocument) {
  const remaining = document.items.filter((item) => !item.completed);
  return {
    title: document.title,
    summary: `${document.items.length - remaining.length}/${document.items.length} completed · Due ${document.deadline}`,
    highlights: remaining.slice(0, 5).map((item) => `☐ ${item.title} · ${item.deadline}`),
    contentText: [document.title, document.description, ...document.items.map((item) => `${item.completed ? "[x]" : "[ ]"} ${item.title} ${item.deadline}`)].join("\n"),
  };
}

function json(summary: SummaryRow, stored: typeof todoLists.$inferSelect, viewerId: string) {
  return { id: summary.id, revision: stored.revision, document: stored.document,
    isOwner: summary.ownerId === viewerId, visibility: summary.visibility,
    shareUrl: shareUrlFor(summary.slug), updatedAt: stored.updatedAt.toISOString() };
}

export async function getTodoList(db: Database, id: string, viewerId: string, ownerOnly = false) {
  const summary = ownerOnly ? await getOwnedSummary(db, id, viewerId) : await findSummaryById(db, id);
  if (!summary || summary.kind !== "todo_list" || !await canViewerRead(db, summary, viewerId)) throw new ApiError(404, "NOT_FOUND", "Todo list not found");
  const [stored] = await db.select().from(todoLists).where(eq(todoLists.summaryId, id));
  if (!stored) throw new ApiError(404, "NOT_FOUND", "Todo list not found");
  return json(summary, stored, viewerId);
}

export async function listTodoLists(db: Database, ownerId: string) {
  const rows = await db.select({ summary: summaries, stored: todoLists }).from(todoLists)
    .innerJoin(summaries, eq(summaries.id, todoLists.summaryId)).where(eq(summaries.ownerId, ownerId)).orderBy(desc(todoLists.updatedAt)).limit(200);
  return { todoLists: rows.map(({ summary, stored }) => json(summary, stored, ownerId)) };
}

/** Queue in the same transaction as the document. Deterministic keys retain delivery receipts on unchanged deadlines. */
function events(db: Database, id: string, document: TodoDocument, createdByAI: boolean, now: Date, fenced = false) {
  const values = [
    ...(createdByAI ? [{ itemId: null, kind: "created" as const, dueAt: now }] : []),
    ...(document.items.some((item) => !item.completed) ? [{ itemId: null, kind: "deadline" as const, dueAt: new Date(document.deadline) }] : []),
    ...document.items.filter((item) => !item.completed).map((item) => ({ itemId: item.id, kind: "deadline" as const, dueAt: new Date(item.deadline) })),
  ];
  // JSON tuple avoids ambiguous ids. Every SELECT uses the document revision as its fence,
  // rather than changes(), because ON CONFLICT DO NOTHING changes that connection-local value.
  return values.map((event) => db.run(sql`INSERT INTO todo_notifications (id, summary_id, item_id, kind, due_at)
    SELECT ${JSON.stringify([id, event.kind, event.itemId, event.dueAt.getTime()])}, ${id}, ${event.itemId}, ${event.kind}, ${event.dueAt.getTime()}
    WHERE ${fenced ? sql`EXISTS (SELECT 1 FROM todo_lists WHERE summary_id = ${id} AND document = ${JSON.stringify(document)})` : sql`1`}
    ON CONFLICT(id) DO NOTHING`));
}

export async function createTodoList(db: Database, principal: ApiPrincipal, input: { document: TodoDocument; visibility: Visibility }, actor: "owner" | "agent" = "owner") {
  const document = todoDocumentSchema.parse(input.document);
  const now = new Date();
  const id = crypto.randomUUID();
  const digest = todoDigest(document);
  const stored = { summaryId: id, document, revision: 0, updatedAt: now };
  const row = await insertSummary(db, getObjectStore(), {
    id, ownerId: principal.sub, kind: "todo_list", sourceType: "text", source: "text",
    sourceUrl: null, sourceTitle: null, siteName: null, sourceFileKey: null,
    ...digest, contentExcerpt: digest.contentText.slice(0, 1200), contentMarkdown: document.description,
    category: "Other", tags: ["todo"], keywords: [], language: "en", sourceLanguage: null, displayLanguage: null,
    theme: { colors: ["#12372A", "#436850"], mode: "dark", emoji: "☑️", accent: "#ADBC9F" },
    ogHeadline: document.title, imageStyle: "graphic", ogImageKey: null, artImageKey: null,
    visibility: input.visibility, ttlDays: null, expiresAt: null, viewCount: 0, createdAt: now, updatedAt: now,
  }, Promise.resolve(null), () => [db.insert(todoLists).values(stored), ...events(db, id, document, actor === "agent", now)], document, { actor });
  if (actor === "agent") runAfter(() => deliverTodoNotifications(db));
  return json(row, stored, principal.sub);
}

export async function updateTodoList(db: Database, ownerId: string, id: string, input: { document: TodoDocument; revision: number }, actor: VersionActor = "owner", restoredFrom?: number) {
  const current = await getTodoList(db, id, ownerId, true);
  if (current.revision !== input.revision) throw new ApiError(409, "TODO_REVISION_CONFLICT", "The list changed. Reload before saving.");
  const document = todoDocumentSchema.parse(input.document);
  const now = new Date();
  const digest = todoDigest(document);
  const translations = await db.select({ key: summaryTranslations.ogImageKey }).from(summaryTranslations).where(eq(summaryTranslations.summaryId, id));
  const [saveVersion, trimVersions] = versionStatements(db, { id, kind: "todo_list" }, document, { at: now, actor, restoredFrom, fenced: true });
  const [saved] = await db.batch([
    db.update(todoLists).set({ document, revision: input.revision + 1, updatedAt: now }).where(and(eq(todoLists.summaryId, id), eq(todoLists.revision, input.revision))),
    db.update(summaries).set({ ...digest, contentMarkdown: document.description, contentExcerpt: digest.contentText.slice(0, 1200), updatedAt: now }).where(and(eq(summaries.id, id), sql`changes() > 0`)),
    saveVersion,
    // The successful version insert keeps the CAS fence alive even if there are no translations.
    db.delete(summaryTranslations).where(and(eq(summaryTranslations.summaryId, id), sql`changes() > 0`)),
    trimVersions,
    ...events(db, id, document, false, now, true),
  ]);
  if (!saved.rowsAffected) throw new ApiError(409, "TODO_REVISION_CONFLICT", "The list changed. Reload before saving.");
  runAfter(() => Promise.all(translations.filter((row) => row.key).map((row) => getObjectStore().delete(row.key!).catch(() => {}))));
  return getTodoList(db, id, ownerId);
}
