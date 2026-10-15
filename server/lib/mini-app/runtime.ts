import { and, eq, gt, sql } from "drizzle-orm";
import type { Database } from "@/lib/db/client";
import { miniAppRuns, miniAppConnections, miniAppConnectionGrants } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { validateFields, type Json, type MiniAppDocument, type MiniRun, type MiniStep } from "@/lib/contracts/mini-app";
import { evaluate, writePath } from "./expressions";
import { callMiniConnector } from "./connections";
import { fingerprint } from "./secrets";
import { miniAccess, mutateMiniRecord, queryMiniRecords } from "./service";
import { runMiniScript } from "./scripts";
import { validMiniApp } from "./validation";

type Effects = { type: "present" | "dismiss"; target?: string }[];
interface Operations {
  query: (query: string, context: Record<string, Json>, cursor?: string) => Promise<Json>;
  mutate: (step: Extract<MiniStep, { type: "mutate" }>, context: Record<string, Json>) => Promise<void>;
  request: (connector: string, operation: string, input: Json) => Promise<Json>;
  check: () => Promise<void>;
}
async function execute(document: MiniAppDocument, input: Omit<MiniRun, "key" | "revision">, ops: Operations, budgetDeadline = Date.now() + 30_000) {
  const action = document.actions[input.action];
  if (!action) throw new ApiError(404, "MINI_ACTION_NOT_FOUND", "Action not found");
  validateFields(input.input, action.input);
  const state = structuredClone(input.state); const effects: Effects = [];
  const context: Record<string, Json> = { state, input: input.input, item: input.item ?? null };
  let count = 0; const deadline = budgetDeadline;
  const steps = async (list: MiniStep[]) => {
    for (const step of list) {
      if (++count > 50 || Date.now() > deadline) throw new ApiError(422, "MINI_ACTION_LIMIT", "Action exceeded its execution budget");
      await ops.check();
      switch (step.type) {
        case "set": writePath(state, step.path, evaluate(step.value, context)); break;
        case "query": writePath(state, step.into, await ops.query(step.query, context, step.cursor ? String(evaluate(step.cursor, context) ?? "") || undefined : undefined)); break;
        case "mutate": await ops.mutate(step, context); break;
        case "request": writePath(state, step.into, await ops.request(step.connector, step.operation, evaluate(step.input, context))); break;
        case "script": writePath(state, step.into, await runMiniScript(document.scripts[step.script], evaluate(step.input, context))); break;
        case "if": await steps(evaluate(step.condition, context) ? step.then : step.else ?? []); break;
        case "present": effects.push({ type: "present", target: step.target }); break;
        case "dismiss": effects.push({ type: "dismiss" }); break;
      }
      if (Buffer.byteLength(JSON.stringify(state)) > 1024 * 1024) throw new ApiError(422, "MINI_STATE_LIMIT", "App state exceeds 1 MiB");
    }
  };
  await steps(action.steps);
  return { state, effects };
}
export async function runMiniAction(db: Database, appId: string, userId: string, input: MiniRun) {
  const access = await miniAccess(db, appId, userId);
  if (access.app.revision !== input.revision) throw new ApiError(409, "MINI_REVISION_CONFLICT", "The app changed. Reload before running this action.");
  // Bind replay data to the current permission snapshot, so revocation also revokes cached results.
  const connectionAccess = await db.select({ id: miniAppConnections.id, status: miniAppConnections.status, fingerprint: miniAppConnections.fingerprint, operations: miniAppConnectionGrants.operations }).from(miniAppConnections)
    .leftJoin(miniAppConnectionGrants, and(eq(miniAppConnectionGrants.connectionId, miniAppConnections.id), eq(miniAppConnectionGrants.email, access.email)))
    .where(eq(miniAppConnections.appId, appId)).orderBy(miniAppConnections.id);
  const hash = fingerprint({ input, permissions: access.permissions, connectionAccess }); const id = crypto.randomUUID();
  const [claimed] = await db.insert(miniAppRuns).values({ id, appId, userId, key: input.key, fingerprint: hash, status: "running" }).onConflictDoNothing().returning();
  if (!claimed) {
    const [previous] = await db.select().from(miniAppRuns).where(and(eq(miniAppRuns.appId, appId), eq(miniAppRuns.userId, userId), eq(miniAppRuns.key, input.key)));
    if (!previous || previous.fingerprint !== hash) throw new ApiError(409, "MINI_IDEMPOTENCY_CONFLICT", "This request key belongs to another action");
    if (previous.status === "complete") return previous.result;
    throw new ApiError(409, "MINI_ACTION_ALREADY_STARTED", "This action has already started. Refresh before trying a new action.", { status: previous.status });
  }
  let externalWriteStarted = false;
  try {
    const [count] = await db.select({ n: sql<number>`count(*)` }).from(miniAppRuns).where(and(eq(miniAppRuns.userId, userId), gt(miniAppRuns.createdAt, new Date(Date.now() - 60_000))));
    if (count.n > 120) throw new ApiError(429, "MINI_RATE_LIMIT", "Too many actions. Try again shortly.");
    const result = await execute(access.app.document, input, {
      check: async () => { const current = await miniAccess(db, appId, userId); if (current.app.revision !== input.revision) throw new ApiError(409, "MINI_REVISION_CONFLICT", "The app changed during this action"); },
      query: async (key, context, cursor) => queryMiniRecords(db, appId, userId, access.app.document.queries[key], context, cursor),
      mutate: async (step, context) => {
        await mutateMiniRecord(db, appId, userId, step.table, step.operation, { id: step.recordId ? String(evaluate(step.recordId, context)) : undefined, revision: step.revision === undefined ? undefined : Number(evaluate(step.revision, context)), data: step.value ? evaluate(step.value, context) : {} });
      },
      request: async (connector, operation, data) => {
        externalWriteStarted ||= access.app.document.connectors[connector].operations[operation].method !== "GET";
        return callMiniConnector(db, appId, userId, connector, operation, data);
      },
    });
    await db.update(miniAppRuns).set({ status: "complete", result }).where(eq(miniAppRuns.id, id));
    return result;
  } catch (error) {
    await db.update(miniAppRuns).set({ status: externalWriteStarted ? "uncertain" : "failed", result: null }).where(eq(miniAppRuns.id, id));
    if (externalWriteStarted) throw new ApiError(409, "MINI_EXTERNAL_OUTCOME_UNCERTAIN", "The external operation may have completed. Check the service before retrying.");
    throw error;
  }
}
/** Devices run keyless requests themselves; scripts never leave the server sandbox, so they come here one step at a time. */
export async function runMiniScriptStep(db: Database, appId: string, userId: string, input: { revision: number; script: string; input: Json }) {
  const access = await miniAccess(db, appId, userId);
  if (access.app.revision !== input.revision) throw new ApiError(409, "MINI_REVISION_CONFLICT", "The app changed. Reload before running this action.");
  const source = access.app.document.scripts[input.script];
  if (source === undefined) throw new ApiError(404, "MINI_SCRIPT_NOT_FOUND", "Script not found");
  const [count] = await db.select({ n: sql<number>`count(*)` }).from(miniAppRuns).where(and(eq(miniAppRuns.userId, userId), gt(miniAppRuns.createdAt, new Date(Date.now() - 60_000))));
  if (count.n > 120) throw new ApiError(429, "MINI_RATE_LIMIT", "Too many actions. Try again shortly.");
  const id = crypto.randomUUID();
  await db.insert(miniAppRuns).values({ id, appId, userId, key: `script:${id}`, fingerprint: "script", status: "complete" });
  return { value: await runMiniScript(source, input.input) };
}
/** Preview never touches a user's database or connections. Sample records are supplied by the preview only. */
export async function previewMiniAction(raw: unknown, input: Omit<MiniRun, "key" | "revision">, suppliedRecords?: Record<string, Json[]>) {
  const document = await validMiniApp(raw);
  return executeMiniFixture(document, input, suppliedRecords);
}
export async function executeMiniFixture(document: MiniAppDocument, input: Omit<MiniRun, "key" | "revision">, suppliedRecords?: Record<string, Json[]>, deadline?: number) {
  const records: Record<string, Json[]> = structuredClone(suppliedRecords ?? Object.fromEntries(Object.entries(document.fixtures.records).map(([key, items]) => [key, items.map((data, i) => ({ id: `sample-${i}`, revision: 0, data }))])));
  const result = await execute(document, input, {
    check: async () => {},
    query: async (key, context, cursor) => {
      const query = document.queries[key];
      const field = (row: Json, key: string): Json => ((row as { data: Record<string, Json> }).data[key]) ?? null;
      const rows = (records[query.table] ?? []).filter(row => query.filters.every(filter => !!evaluate({ op: filter.op, args: [field(row, filter.field), evaluate(filter.value, context)] }, {})));
      if (query.sort) { const sort = query.sort; rows.sort((a, b) => { const x = field(a, sort.field); const y = field(b, sort.field); return (x === y ? 0 : x === null ? -1 : y === null ? 1 : x < y ? -1 : 1) * (sort.direction === "desc" ? -1 : 1); }); }
      const offset = Number(cursor ?? 0);
      if (!Number.isSafeInteger(offset) || offset < 0 || offset > 100_000) throw new ApiError(400, "INVALID_CURSOR", "Invalid cursor");
      return { items: rows.slice(offset, offset + query.limit), nextCursor: rows.length > offset + query.limit ? String(offset + query.limit) : null };
    },
    mutate: async (step, context) => {
      const rows = records[step.table] ??= [];
      const value = step.value ? evaluate(step.value, context) : {};
      if (step.operation !== "delete") validateFields(value, document.tables[step.table].fields);
      if (step.operation === "create") rows.push({ id: crypto.randomUUID(), revision: 0, data: value });
      else {
        const id = evaluate(step.recordId ?? null, context);
        const index = rows.findIndex(row => row && typeof row === "object" && !Array.isArray(row) && row.id === id);
        if (index < 0) throw new ApiError(409, "MINI_RECORD_CONFLICT", "Sample record not found");
        if (step.operation === "delete") rows.splice(index, 1); else rows[index] = { id, revision: Number(evaluate(step.revision ?? 0, context)) + 1, data: value };
      }
    },
    request: async (connector, operation) => document.fixtures.responses[`${connector}_${operation}`] ?? null,
  }, deadline);
  return { ...result, records };
}
