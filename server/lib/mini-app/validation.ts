import { isDeepStrictEqual } from "node:util";
import { boundedMiniJson } from "./bounds";
import { miniAppDocumentSchema, miniDocumentIssues, type MiniAppDocument } from "@/lib/contracts/mini-app";
import { ApiError } from "@/lib/http/errors";
import { runMiniScript } from "./scripts";
export async function validateMiniApp(input: unknown): Promise<{ ok: boolean; issues: string[]; document?: MiniAppDocument }> {
  if (!boundedMiniJson(input)) return { ok: false, issues: ["Document is too large or deeply nested"] };
  const parsed = miniAppDocumentSchema.safeParse(input);
  if (!parsed.success) return { ok: false, issues: parsed.error.issues.slice(0, 30).map(i => `${i.path.join(".")}: ${i.message}`) };
  const issues = miniDocumentIssues(parsed.data);
  if (!issues.length) for (const [name, script] of Object.entries(parsed.data.scripts)) {
    try { await runMiniScript(script, null, true); } catch (e) { issues.push(`${name}: ${e instanceof ApiError ? e.message : "Invalid script"}`); }
  }
  if (!issues.length && parsed.data.fixtures.tests.length) {
    const { executeMiniFixture } = await import("./runtime");
    const deadline = Date.now() + 10_000;
    for (const [i, test] of parsed.data.fixtures.tests.entries()) {
      if (Date.now() >= deadline) { issues.push("Fixture validation exceeded ten seconds"); break; }
      try {
        const result = await executeMiniFixture(parsed.data, { action: test.action, input: test.input, state: { ...parsed.data.initialState, ...test.state } }, undefined, deadline);
        for (const [key, expected] of Object.entries(test.expectState)) if (!isDeepStrictEqual(result.state[key], expected)) issues.push(`fixtures.tests.${i}: state.${key} did not match`);
      } catch (error) { issues.push(`fixtures.tests.${i}: ${error instanceof Error ? error.message : "Fixture failed"}`); }
    }
  }
  return { ok: !issues.length, issues, ...(!issues.length ? { document: parsed.data } : {}) };
}
export async function validMiniApp(input: unknown): Promise<MiniAppDocument> {
  const result = await validateMiniApp(input);
  if (!result.document) throw new ApiError(422, "MINI_APP_INVALID", `Fix the Mini App definition: ${result.issues.slice(0, 3).join("; ")}`, { issues: result.issues });
  return result.document;
}
