import type { InStatement, InValue } from "@libsql/client";
import { and, eq, sql } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createDatabase, type DatabaseHandle } from "@/lib/db/client";
import { paperReferenceChecks, summaries, summaryLikes, summaryViews, users } from "@/lib/db/schema";
import { searchCondition } from "@/lib/services/search";
import { listSummaries } from "@/lib/services/summaries";

let handle: DatabaseHandle;
beforeEach(async () => {
  handle = createDatabase(":memory:");
  await handle.migrate();
  await handle.db.insert(users).values([{ id: "viewer" }, { id: "other" }]);
  await handle.db.insert(summaries).values(Array.from({ length: 120 }, (_, n) => ({
    id: `chip-${String(n).padStart(3, "0")}`, slug: `slug-${n}`, ownerId: n < 3 ? "viewer" : "other",
    sourceType: "text" as const, title: n === 0 ? "AI 人工智能" : "Other",
    summary: "Mixed CASE with literal 50% and a_b and a\\b", highlights: ["Separate field"],
    tags: ["UPPER"], keywords: ["keyword"], category: "Technology", language: "en",
    siteName: n === 0 ? "Example.COM" : null,
    theme: { colors: ["#000000"], mode: "dark" as const, emoji: "", accent: "#000000" },
    createdAt: new Date(1000 + n),
  })));
  await handle.db.insert(summaryViews).values({ userId: "viewer", summaryId: "chip-003", viewedAt: new Date(3000) });
  await handle.db.insert(summaryLikes).values({ userId: "viewer", summaryId: "chip-004", likedAt: new Date(4000) });
});
afterEach(() => { vi.restoreAllMocks(); handle.close(); });

describe("query performance regressions", () => {
  it.each(["all", "mine", "viewed", "liked"] as const)("uses indexed candidates for scope=%s and preserves pagination", async (scope) => {
    const execute = vi.spyOn(handle.client, "execute");
    const page = await listSummaries(handle.db, "viewer", { scope, limit: 2, q: undefined, tag: undefined, cursor: undefined });
    const query = (execute.mock.calls as unknown as [InStatement][]).map(([statement]) => statement)
      .find((statement) => typeof statement !== "string" && statement.sql.startsWith('select ') && statement.sql.includes('"summary_likes"'));
    expect(query).toBeDefined();
    if (!query || typeof query === "string") throw new Error("Missing library SQL");
    const plan = await handle.client.execute({ ...query, sql: `EXPLAIN QUERY PLAN ${query.sql}` });
    const details = plan.rows.map((row) => String(row.detail));
    expect(details.some((detail) => /^SCAN summaries\b/.test(detail)), details.join("\n")).toBe(false);
    expect(details.some((detail) => /SEARCH summaries USING INDEX/.test(detail)), details.join("\n")).toBe(true);
    const ids = page.items.map((row) => row.id);
    if (page.nextCursor) {
      const next = await listSummaries(handle.db, "viewer", { scope, limit: 2, q: undefined, tag: undefined, cursor: page.nextCursor });
      ids.push(...next.items.map((row) => row.id));
      expect(next.nextCursor).toBeNull();
    }
    expect(ids).toEqual(scope === "all" ? ["chip-003", "chip-002", "chip-001", "chip-000"]
      : scope === "mine" ? ["chip-002", "chip-001", "chip-000"]
      : scope === "viewed" ? ["chip-003"] : ["chip-004"]);
  });

  it("covers the complete paper status read from the new index", async () => {
    const query = handle.db.select().from(paperReferenceChecks).where(eq(paperReferenceChecks.summaryId, "paper")).toSQL();
    const plan = await handle.client.execute({ sql: `EXPLAIN QUERY PLAN ${query.sql}`, args: query.params as InValue[] });
    expect(plan.rows.map((row) => row.detail).join("\n")).toContain("USING COVERING INDEX paper_reference_checks_status_cover_idx");
  });

  it.each(["AI", "人工智能", "case", "UPPER", "Example.com", "50%", "a_b", "a\\b", "AI ai AI", "AI keyword"])("preserves substring matching for %s", async (q) => {
    const rows = await handle.db.select({ id: summaries.id }).from(summaries)
      .where(and(eq(summaries.ownerId, "viewer"), searchCondition(q)));
    expect(rows.map((row) => row.id)).toEqual(q.toLowerCase().includes("ai") || q === "人工智能" || q === "Example.com"
      ? ["chip-000"] : ["chip-000", "chip-001", "chip-002"]);
  });

  it("does not turn escaped wildcards into broad matches or match across field boundaries", async () => {
    for (const q of ["51%", "a%b", "aXb", "AISeparate", "missing keyword"]) {
      const rows = await handle.db.select({ id: summaries.id }).from(summaries).where(searchCondition(q));
      expect(rows, q).toEqual([]);
    }
    const unicode = await handle.db.get<{ same: number }>(sql`SELECT 'Æ' LIKE 'æ' AS same`);
    expect(unicode?.same).toBe(0);
  });
});
