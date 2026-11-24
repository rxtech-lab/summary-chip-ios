import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as proposals from "@/app/api/v1/resumes/[id]/proposals/route";
import * as apply from "@/app/api/v1/resumes/[id]/proposals/[proposalId]/apply/route";
import * as edits from "@/app/api/v1/resumes/[id]/operations/route";
import * as create from "@/app/api/v1/resumes/route";
import * as live from "@/app/api/v1/chat/live/tool/route";
import * as keys from "@/app/api/v1/api-keys/route";
import * as mcp from "@/app/api/mcp/route";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";
import type { ResolvedResume } from "@/lib/services/resumes";

import { getResumeProposal, runResumeProposal } from "@/lib/resume/proposals";
import { resumeProposals } from "@/lib/db/schema";
import { eq } from "drizzle-orm";

const startWorkflow = vi.hoisted(() => vi.fn());
vi.mock("workflow/api", async (importOriginal) => ({
  ...(await importOriginal<typeof import("workflow/api")>()),
  start: startWorkflow,
}));
let env: TestEnv;
beforeEach(async () => {
  env = await setupTestEnv();
  env.ai.translates = true;
  startWorkflow.mockReset();
});
afterEach(() => {
  env.teardown();
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
});
const doc = { version: 1, candidateName: "Ming", headline: "Engineer", links: [], sections: [] };
const request = (body: unknown, token = env.tokens.alice) => apiRequest("POST", "/api/v1/resumes", { token, body });
async function created() {
  const res = await create.POST(request({ language: "en", title: "CV", document: doc, idempotencyKey: "create" }));
  expect(res.status).toBe(201);
  return (await res.json()) as ResolvedResume;
}
const scope = (r: ResolvedResume) => ({
  language: r.language,
  variantId: r.variantId,
  expectedRevisionToken: r.revisionToken,
});
const propose = (r: ResolvedResume, key: string) =>
  proposals.POST(
    request({ ...scope(r), kind: "translate", targetLanguage: "fr", idempotencyKey: key }),
    params({ id: r.familyId }),
  );
async function save(r: ResolvedResume, value: string) {
  const res = await edits.POST(
    request({
      ...scope(r),
      operations: [{ op: "set", path: "/headline", value }],
      idempotencyKey: crypto.randomUUID(),
    }),
    params({ id: r.familyId }),
  );
  expect(res.status).toBe(200);
  return (await res.json()) as ResolvedResume;
}
function accept(r: ResolvedResume, proposalId: string, acceptedPaths: string[], keepPaths?: string[]) {
  return apply.POST(
    request({
      expectedRevisionToken: r.revisionToken,
      idempotencyKey: "apply-" + proposalId,
      acceptedPaths,
      keepPaths,
    }),
    params({ id: r.familyId, proposalId }),
  );
}
describe("résumé proposals and focused calls", () => {
  it("deduplicates translation and flags hand-edited wording on refresh", async () => {
    const source = await created();
    const job = await (await propose(source, "translate-1")).json();
    expect(job.status).toBe("ready");
    expect(await (await propose(source, "translate-1")).json()).toEqual(job);
    expect(env.ai.calls.translateStrings).toHaveLength(1);
    const applied = await accept(
      source,
      job.id,
      job.findings.map((f: { path: string }) => f.path),
    );
    expect(applied.status).toBe(200);
    const french = (await applied.json()) as ResolvedResume;
    expect(french.document.headline).toBe("[fr] Engineer");
    await save(french, "Ingénieure");
    const updated = await save(source, "Senior Engineer");
    const refresh = await (await propose(updated, "refresh")).json();
    expect(refresh.findings).toMatchObject([
      { path: "/headline", current: "Ingénieure", source: "Senior Engineer", conflict: true },
    ]);
    expect(env.ai.calls.translateStrings.at(-1)?.texts).toEqual(["Senior Engineer"]);
    const kept = await accept(updated, refresh.id, [], ["/headline"]);
    expect(kept.status).toBe(200);
    expect((await kept.json()).document.headline).toBe("Ingénieure");
  });
  it("refuses stale proposals and cross-owner reads before model execution", async () => {
    const source = await created();
    const job = await (await propose(source, "translate-1")).json();
    await save(source, "Updated");
    expect((await accept(source, job.id, ["/headline"])).status).toBe(409);
    const wrong = await proposals.POST(
      request({ ...scope(source), kind: "review", idempotencyKey: "bob" }, env.tokens.bob),
      params({ id: source.familyId }),
    );
    expect(wrong.status).toBe(404);
  });
  it("routes voice tool edits to the captured company, checks ownership and deduplicates a call ID", async () => {
    const source = await created();
    const voice = (token: string) =>
      live.POST(
        request(
          {
            context: {
              messages: [{ role: "user", parts: [{ type: "text", text: "Change my headline" }] }],
              resumeTarget: {
                familyId: source.familyId,
                variantId: null,
                language: "en",
                revisionToken: source.revisionToken,
              },
            },
            name: "editResume",
            callId: "call-abc",
            input: {
              argumentsJson: JSON.stringify({
                expectedRevisionToken: source.revisionToken,
                operations: [{ op: "set", path: "/headline", value: "Architect" }],
              }),
            },
          },
          token,
        ),
      );
    expect((await voice(env.tokens.bob)).status).toBe(404);
    const res = await voice(env.tokens.alice);
    expect(res.status).toBe(200);
    const first = await res.json();
    expect(first.output).toMatchObject({
      familyId: source.familyId,
      language: "en",
      document: { headline: "Architect" },
    });
    expect(await (await voice(env.tokens.alice)).json()).toEqual(first);
  });
  it("reserves before execution, charges one completed request and releases failures", async () => {
    const source = await created();
    vi.stubEnv("RX_SUBSCRIPTION_ENVIRONMENT", "sandbox");
    vi.stubEnv("RX_SUBSCRIPTION_URL", "https://subscription.test");
    vi.stubEnv("RX_SUBSCRIPTION_API_KEY", "rxs_sandbox_example");
    let insufficient = true;
    const bodies: { url: string; amount: number; idempotencyKey: string }[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string, init: RequestInit) => {
        const payload = JSON.parse(String(init.body));
        bodies.push({ url, ...payload });
        if (url.endsWith("/reserve") && insufficient)
          return Response.json({ error: "insufficient_balance" }, { status: 409 });
        return Response.json(url.endsWith("/reserve") ? { reservationId: "reservation" } : { status: "closed" });
      }),
    );
    expect((await propose(source, "empty")).status).toBe(402);
    expect(env.ai.calls.translateStrings).toHaveLength(0);
    insufficient = false;
    expect((await propose(source, "paid")).status).toBe(200);
    expect((await propose(source, "paid")).status).toBe(200);
    expect(bodies.filter((b) => b.url.endsWith("/settle"))).toHaveLength(1);
    expect(bodies.at(-1)?.amount).toBeGreaterThan(0);
    env.ai.translates = false;
    expect((await propose(source, "failed")).status).toBe(502);
    expect(bodies.at(-1)?.amount).toBe(0);
  });
  it("queues large translations once and refreshes unchanged strings inline", async () => {
    const bullets = Array.from({ length: 65 }, (_, i) => ({ id: "b" + i, text: "Project milestone " + i }));
    const document = {
      ...doc,
      sections: [{ id: "work", kind: "experience", title: "Experience", entries: [{ id: "job", bullets }] }],
    };
    const res = await create.POST(request({ language: "en", title: "CV", document, idempotencyKey: "large" }));
    const source: ResolvedResume = await res.json();
    const job = await (await propose(source, "background")).json();
    expect(job.status).toBe("queued");
    expect(startWorkflow).toHaveBeenCalledTimes(1);
    await propose(source, "background");
    expect(startWorkflow).toHaveBeenCalledTimes(1);
    await runResumeProposal(env.handle.db, job.id);
    await runResumeProposal(env.handle.db, job.id);
    const done = await getResumeProposal(env.handle.db, "user-alice", source.familyId, job.id);
    expect(done.status).toBe("ready");
    const saved = await accept(
      source,
      job.id,
      done.findings.map((f) => f.path),
    );
    expect(saved.status).toBe(200);
    const next = await (await propose(source, "refresh-background")).json();
    expect(next).toMatchObject({ status: "ready", findings: [] });
    expect(startWorkflow).toHaveBeenCalledTimes(1);
    expect(env.ai.calls.translateStrings).toHaveLength(1);
  });
  it("reports a lost job as failed after its execution window", async () => {
    const source = await created(),
      job = await (await propose(source, "lost")).json();
    await env.handle.db
      .update(resumeProposals)
      .set({ status: "running", createdAt: Date.now() - 3600000 })
      .where(eq(resumeProposals.id, job.id));
    expect(await getResumeProposal(env.handle.db, "user-alice", source.familyId, job.id)).toMatchObject({
      status: "failed",
      error: "RESUME_JOB_TIMED_OUT",
    });
  });
  it("creates and translates through the authenticated MCP endpoint", async () => {
    const key = (await (await keys.POST(request({ name: "résumé test" }))).json()).key;
    async function call(name: string, args: unknown) {
      const res = await mcp.POST(
        apiRequest("POST", "/api/mcp", {
          token: key,
          headers: { accept: "application/json, text/event-stream" },
          body: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } },
        }),
      );
      expect(res.status).toBe(200);
      const result = (await res.json()).result;
      expect(result.isError, result.content[0]?.text).toBeFalsy();
      return result.structuredContent;
    }
    const source = await call("create_resume", {
      language: "en",
      title: "CV",
      document: doc,
      idempotencyKey: "mcp-create",
    });
    const job = await call("translate_resume", {
      familyId: source.familyId,
      ...scope(source),
      targetLanguage: "fr",
      idempotencyKey: "mcp-translate",
    });
    expect(job.status).toBe("ready");
    const result = await call("apply_resume_proposal", {
      familyId: source.familyId,
      proposalId: job.id,
      acceptedPaths: ["/headline"],
      expectedRevisionToken: source.revisionToken,
      idempotencyKey: "mcp-apply",
    });
    expect(result.document.headline).toBe("[fr] Engineer");
  });
});
