import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as devicesRoute from "@/app/api/v1/devices/route";
import * as papersRoute from "@/app/api/v1/papers/route";
import * as paperRoute from "@/app/api/v1/papers/[id]/route";
import { paperNotificationBatches as batches } from "@/lib/db/schema";
import { setPaperNotifierForTests } from "@/lib/papers/notifier";
import { deliverPaperNotification, PAPER_NOTIFICATION_DELAY_MS, planPaperNotification, resumePaperNotifications } from "@/lib/services/paper-notifications";
import { applyPaperEdits, type PaperJson } from "@/lib/services/papers";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

const { sendPush, apnsConfigured } = vi.hoisted(() => ({ sendPush: vi.fn(), apnsConfigured: vi.fn() }));
vi.mock("@/lib/notifications/apns", () => ({ sendPush, apnsConfigured }));

const FABRICATED = "\n@article{ghost2031,\n  author = {A. Nobody},\n  title = {A Fabricated Survey of Gears},\n  year = {2031}\n}\n";
let env: TestEnv;
let started: string[];

beforeEach(async () => {
  env = await setupTestEnv();
  vi.stubEnv("SUMMARY_OG_REMOTE_ASSETS", "false");
  sendPush.mockReset().mockResolvedValue({ status: 200 });
  apnsConfigured.mockReset().mockReturnValue(true);
  started = [];
  setPaperNotifierForTests({ start: async (id) => { started.push(id); } });
  expect((await devicesRoute.POST(apiRequest("POST", "/api/v1/devices", { token: env.tokens.alice,
    body: { installationId: crypto.randomUUID(), token: "a".repeat(64), environment: "sandbox", platform: "ios" },
  }))).status).toBe(204);
});
afterEach(() => { env.teardown(); vi.unstubAllEnvs(); });

async function createPaper(): Promise<PaperJson> {
  const response = await papersRoute.POST(apiRequest("POST", "/api/v1/papers", { token: env.tokens.alice, body: { title: "Quantum Gears" } }));
  expect(response.status).toBe(201);
  return (await response.json()).paper;
}

async function pending(id: string) {
  const [row] = await env.handle.db.select().from(batches).where(eq(batches.paperId, id));
  return row;
}

/** Runs the workflow's steps once the quiet period is over. */
async function run(id: string) {
  const row = await pending(id);
  const plan = await planPaperNotification(env.handle.db, id, "runner", row.dueAt);
  expect(plan.status).toBe("deliver");
  if (plan.status !== "deliver") throw new Error("Expected delivery");
  return deliverPaperNotification(env.handle.db, id, "runner", plan.revision);
}

function alerts(): Array<{ aps: { alert: { title: string; body: string } }; paperId?: string }> {
  return sendPush.mock.calls.map((call) => call[1]);
}

describe("paper notifications", () => {
  it("debounces a new paper and the agent edits after it into one \"Paper added\" alert", async () => {
    const paper = await createPaper();
    await vi.waitFor(() => expect(started).toEqual([paper.id]));
    const first = await pending(paper.id);
    expect(first).toMatchObject({ created: true, revision: 0 });
    expect(first.dueAt.getTime() - Date.now()).toBeGreaterThan(PAPER_NOTIFICATION_DELAY_MS - 10_000);
    expect(await planPaperNotification(env.handle.db, paper.id, "runner", new Date(first.dueAt.getTime() - 1))).toEqual({ status: "wait", nextAt: first.dueAt.getTime() });

    await applyPaperEdits(env.handle.db, "user-alice", paper.id, { operations: [{ op: "set_title", title: "Quantum Gears, Revised" }] });
    expect(await pending(paper.id)).toMatchObject({ created: true, revision: 1 });

    expect(await run(paper.id)).toBe(true);
    expect(await pending(paper.id)).toBeUndefined();
    expect(alerts().filter((alert) => alert.aps.alert.title === "Paper added")).toEqual([
      expect.objectContaining({ paperId: paper.id, aps: expect.objectContaining({ alert: { title: "Paper added", body: "Quantum Gears, Revised" } }) }),
    ]);

    await applyPaperEdits(env.handle.db, "user-alice", paper.id, { operations: [{ op: "set_title", title: "Quantum Gears III" }] });
    expect(await pending(paper.id)).toMatchObject({ created: false, revision: 2 });
    expect(await run(paper.id)).toBe(true);
    expect(alerts().at(-1)?.aps.alert.title).toBe("Paper updated");
  });

  it("doesn't alert the owner about their own autosaves, and a save during delivery waits again", async () => {
    const paper = await createPaper();
    const row = await pending(paper.id);
    const plan = await planPaperNotification(env.handle.db, paper.id, "runner", row.dueAt);
    if (plan.status !== "deliver") throw new Error("Expected delivery");
    await applyPaperEdits(env.handle.db, "user-alice", paper.id, { operations: [{ op: "set_title", title: "Moved on" }] });
    expect(await deliverPaperNotification(env.handle.db, paper.id, "runner", plan.revision)).toBe(false);
    expect(await run(paper.id)).toBe(true);

    const current = (await (await paperRoute.GET(apiRequest("GET", `/api/v1/papers/${paper.id}`, { token: env.tokens.alice }), params({ id: paper.id }))).json()).paper as PaperJson;
    const saved = await paperRoute.PUT(apiRequest("PUT", `/api/v1/papers/${paper.id}`, { token: env.tokens.alice,
      body: { title: "Typed by hand", files: current.files, mainFile: current.mainFile, compiler: current.compiler, revision: current.revision },
    }), params({ id: paper.id }));
    expect(saved.status).toBe(200);
    expect(await pending(paper.id)).toBeUndefined();
  });

  it("restarts overdue batches from the cron", async () => {
    const paper = await createPaper();
    const row = await pending(paper.id);
    started = [];
    expect(await resumePaperNotifications(env.handle.db, new Date(row.dueAt.getTime() - 1))).toEqual({ restartedPapers: 0 });
    expect(await resumePaperNotifications(env.handle.db, row.dueAt)).toEqual({ restartedPapers: 1 });
    expect(started).toEqual([paper.id]);
  });

  it("alerts the owner when a reference check finds errors", async () => {
    const paper = await createPaper();
    const bib = paper.files.find((file) => file.path === "references.bib")!.content;
    await applyPaperEdits(env.handle.db, "user-alice", paper.id, { operations: [{ op: "write_file", path: "references.bib", content: bib + FABRICATED }] });
    await vi.waitFor(() => expect(alerts().map((alert) => alert.aps.alert)).toContainEqual({ title: "Reference check found problems", body: "Quantum Gears: ghost2031" }));
    const call = sendPush.mock.calls.find((entry) => entry[1].aps.alert.title === "Reference check found problems");
    expect(call?.[2]).toEqual({ collapseId: `paper-references:${paper.id}` });
  });
});
