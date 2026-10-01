import { describe, expect, it } from "vitest";
import { focusedSummaryInstructions } from "@/lib/ai/chat";
import { grepLines, LOCAL_INLINE_LIMIT, localFileTools, readLines, splitLines } from "@/lib/ai/local-file";
import type { SummaryRow } from "@/lib/db/schema";

const lines = splitLines("Intro\r\nRevenue grew 12%\nCosts fell\n\nrevenue outlook (2027)\nEnd");

describe("grepLines", () => {
  it("matches literally and case-insensitively by default, with 1-based line numbers", () => {
    const result = grepLines(lines, { pattern: "revenue" });
    expect(result).toEqual({
      matches: [{ line: 2, text: "Revenue grew 12%" }, { line: 5, text: "revenue outlook (2027)" }],
      totalMatches: 2,
      truncated: false,
    });
    expect(grepLines(lines, { pattern: "(2027)" })).toMatchObject({ totalMatches: 1 });
    expect(grepLines(lines, { pattern: "revenue", caseSensitive: true })).toMatchObject({ totalMatches: 1 });
  });

  it("supports regexes, context and a match cap", () => {
    expect(grepLines(lines, { pattern: "^(Costs|End)", regex: true })).toMatchObject({ totalMatches: 2 });
    const capped = grepLines(lines, { pattern: "e", maxMatches: 1, contextLines: 1 });
    expect(capped).toMatchObject({ totalMatches: 4, truncated: true });
    expect("matches" in capped && capped.matches).toEqual([{ line: 2, text: "Revenue grew 12%", before: ["Intro"], after: ["Costs fell"] }]);
  });

  it("reports invalid and risky regexes instead of throwing", () => {
    expect(grepLines(lines, { pattern: "(", regex: true })).toEqual({ error: "Invalid regular expression." });
    expect(grepLines(lines, { pattern: "(a+)+$", regex: true })).toHaveProperty("error");
  });
});

describe("readLines", () => {
  it("reads an inclusive, numbered range and clamps to the file", () => {
    expect(readLines(lines, 2, 3)).toEqual({ startLine: 2, endLine: 3, totalLines: 6, text: "2: Revenue grew 12%\n3: Costs fell", truncated: false });
    expect(readLines(lines, 5, 99)).toMatchObject({ endLine: 6, truncated: false });
    expect(readLines(lines, 7)).toHaveProperty("error");
    expect(readLines(lines, 4, 2)).toHaveProperty("error");
  });

  it("caps very large reads", () => {
    const big = splitLines(Array.from({ length: 1_000 }, (_, i) => `line ${i + 1} ${"x".repeat(150)}`).join("\n"));
    const result = readLines(big, 1, 1_000);
    expect(result).toMatchObject({ startLine: 1, truncated: true });
    expect("endLine" in result && result.endLine).toBeLessThan(400);
  });
});

describe("local file chat", () => {
  const row = { id: "s1", title: "Report", sourceTitle: "Report", siteName: null, sourceUrl: null, summary: "A report.", highlights: [], sourceType: "local", contentText: "", contentExcerpt: "" } as unknown as SummaryRow;

  it("exposes the tools and previews long files instead of inlining them", async () => {
    expect(Object.keys(localFileTools("a"))).toEqual(["grepLocalFile", "readLocalFile"]);
    const short = focusedSummaryInstructions(row, "Revenue grew");
    expect(short).toContain("grepLocalFile");
    expect(short).toContain("shown in full");
    const long = focusedSummaryInstructions(row, `${"a".repeat(LOCAL_INLINE_LIMIT)}SECRET_TAIL`);
    expect(long).not.toContain("SECRET_TAIL");
    expect(long).toContain("preview ends");
  });
});
