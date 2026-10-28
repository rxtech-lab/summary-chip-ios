import { createHash, randomUUID } from "node:crypto";
import { and, desc, eq, lt } from "drizzle-orm";
import { getAiProvider } from "@/lib/ai/provider";
import { podcastVoices } from "@/lib/ai/models";
import { LANGUAGE_NAMES } from "@/lib/ai/summary-schema";
import { podcastPlanScriptSchema, type PodcastCreationInput, type PodcastPlanFrame, type PodcastPlanMessage, type PodcastPlanScript } from "@/lib/contracts/daily-podcast";
import type { Database } from "@/lib/db/client";
import { podcastPlans } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { getObjectStore, ownerKeyPrefix, type ObjectStore } from "@/lib/storage/r2";
import { pointsForCost, reservePodcastPoints, usageCostUsd } from "@/lib/subscription/chat-billing";
import { createDailyPodcast, dailyPodcastChips } from "./daily-podcast";
import { getSummaryForViewer, type ServiceDeps } from "./summaries";

/** Shots that get a storyboard frame; later shots are planned in text only. */
export const MAX_STORYBOARD_FRAMES = 40;
/** Frames drawn at once. */
const FRAME_CONCURRENCY = 4;
/** Chat exchanges kept on a plan. */
const MAX_PLAN_MESSAGES = 60;

type Plan = typeof podcastPlans.$inferSelect;
const changed = () => new ApiError(409, "PODCAST_PLAN_CHANGED", "The plan changed or was confirmed. Reload the plan before continuing.");

/** Frames are keyed by the direction they picture, so unchanged shots keep theirs across revisions and reorders. */
export function storyboardFrameHash(camera: string) {
  return createHash("sha256").update(camera.trim()).digest("hex").slice(0, 16);
}
function frameKey(user: string, plan: string, hash: string) {
  return `${ownerKeyPrefix(user)}/podcast-plans/${plan}/${hash}.png`;
}
/** Each shot's drawn frame, in script order; null for shots without one. */
export function planFrames(plan: Pick<Plan, "script" | "frames">): (PodcastPlanFrame | null)[] {
  return plan.script.segments.map((segment, index) => index < MAX_STORYBOARD_FRAMES ? plan.frames[storyboardFrameHash(segment.camera)] ?? null : null);
}

export async function getPodcastPlan(db: Database, user: string, id: string) {
  const [plan] = await db.select().from(podcastPlans).where(and(eq(podcastPlans.id, id), eq(podcastPlans.ownerId, user)));
  if (!plan) throw new ApiError(404, "NOT_FOUND", "Podcast plan not found.");
  return plan;
}
/** The plan as the app reads it: frame URLs are short-lived private links aligned with the segments. */
export async function publicPodcastPlan(plan: Plan, deps: { store?: ObjectStore; storyboard?: boolean } = {}) {
  const store = deps.store ?? getObjectStore();
  const frames = await Promise.all(planFrames(plan).map(async frame =>
    frame ? (await store.signedGet(frame.key, { inline: true, expiresInSeconds: 3600 }).catch(() => null))?.url ?? null : null));
  return { id: plan.id, revision: plan.revision, confirmed: plan.confirmed, script: plan.script, messages: plan.messages, frames,
    ...(deps.storyboard !== undefined ? { storyboard: deps.storyboard } : {}) };
}
/** Whether this server draws storyboard frames, so the app knows whether missing frames can be drawn. */
async function storyboardEnabled(deps: ServiceDeps) {
  return !!(deps.ai ?? await getAiProvider()).storyboardImageModelId();
}
export async function readPodcastPlan(db: Database, user: string, id: string, deps: ServiceDeps = {}) {
  return publicPodcastPlan(await getPodcastPlan(db, user, id), { store: deps.store, storyboard: await storyboardEnabled(deps) });
}
async function planSources(db: Database, user: string, input: PodcastCreationInput) {
  if (input.summaryId) {
    const chip = await getSummaryForViewer(db, input.summaryId, user);
    if (chip.kind !== "podcast" || chip.ownerId !== user) throw new ApiError(404, "NOT_FOUND", "Podcast not found.");
  }
  const candidates = input.library
    ? await Promise.all([...new Set(input.chipIds ?? [])].map(async id => ({ chip: await getSummaryForViewer(db, id, user) })))
    : await dailyPodcastChips(db, user, input.day);
  const wanted = input.chipIds && new Set(input.chipIds);
  const chips = candidates.filter(({ chip }) => !wanted || wanted.has(chip.id)).map(({ chip }) => chip);
  if (!chips.length || (wanted && chips.length !== wanted.size) || chips.some(chip => chip.kind !== "summary")) {
    throw new ApiError(422, "PODCAST_SELECTION", "Choose readable source summary chips.");
  }
  return chips;
}
function validatePlan(script: PodcastPlanScript, input: PodcastCreationInput, ids: string[], voices: string[]) {
  if (script.segments.some(turn => turn.speaker >= script.speakers.length || !ids.includes(turn.chipId)) ||
      script.speakers.some(speaker => !voices.includes(speaker.voice)) ||
      new Set(script.speakers.map(speaker => speaker.voice)).size !== script.speakers.length ||
      (input.speakerNames && (script.speakers.length !== input.speakerNames.length || script.speakers.some((speaker, index) => speaker.name !== input.speakerNames![index])))) {
    throw new ApiError(422, "PODCAST_PLAN_INVALID", "Use the selected chips, available voices, and chosen speakers.");
  }
}
/** Deletes frames the script no longer uses and returns the ones it keeps. */
async function pruneFrames(store: ObjectStore, plan: Pick<Plan, "script" | "frames">) {
  const used = new Set(plan.script.segments.slice(0, MAX_STORYBOARD_FRAMES).map(segment => storyboardFrameHash(segment.camera)));
  const kept: Record<string, PodcastPlanFrame> = {};
  for (const [hash, frame] of Object.entries(plan.frames)) {
    if (used.has(hash)) kept[hash] = frame;
    else await store.delete(frame.key).catch(() => undefined);
  }
  return kept;
}

export async function createPodcastPlan(db: Database, user: string, input: PodcastCreationInput, deps: ServiceDeps = {}) {
  const chips = await planSources(db, user, input);
  const ai = deps.ai ?? await getAiProvider();
  const model = ai.speechModelId();
  if (!model) throw new ApiError(503, "PODCAST_SPEECH_UNAVAILABLE", "Podcast audio is not available right now.");
  const voices = podcastVoices(model);
  if (input.speakerNames && input.speakerNames.length > voices.length) throw new ApiError(422, "PODCAST_SPEAKERS_UNAVAILABLE", "Choose fewer speakers.");
  const id = randomUUID();
  const charge = await reservePodcastPoints(user, `plan:${id}`, ai.podcastModelId(), deps.billingEnvironment);
  let cost = 0;
  try {
    const pricing = charge ? await ai.podcastPricing() : null;
    const script = podcastPlanScriptSchema.parse(await ai.writePodcast({
      language: LANGUAGE_NAMES[input.language], voices, speakerNames: input.speakerNames, storyboard: true,
      recap: input.recap || !input.library || input.durationSeconds !== undefined,
      maxDurationSeconds: input.recap ? Math.min(179, input.durationSeconds ?? 179) : input.durationSeconds ?? 360, approximateDuration: !input.recap,
      chips: chips.map(chip => ({ id: chip.id, title: chip.title, summary: chip.summary, highlights: chip.highlights })),
    }, { abortSignal: AbortSignal.timeout(100_000), onUsage: usage => { if (pricing) cost += usageCostUsd(usage, pricing); } }));
    validatePlan(script, input, chips.map(chip => chip.id), voices);
    const now = (deps.now?.() ?? new Date()).getTime();
    await db.insert(podcastPlans).values({ id, ownerId: user, input: { ...input, regenerate: true }, script, createdAt: now, updatedAt: now });
    await charge?.settle(Math.max(1, pointsForCost(cost)), { plan: true, textCostUsd: cost });
    return readPodcastPlan(db, user, id, { ...deps, ai });
  } catch (error) { await charge?.settle(0, { failed: true }); throw error; }
}

/** Saves a reviewed script (edited lines). Shots whose direction changed lose their frame until it is redrawn. */
export async function revisePodcastPlan(db: Database, user: string, id: string, revision: number, script: PodcastPlanScript, deps: ServiceDeps = {}) {
  const plan = await getPodcastPlan(db, user, id);
  if (plan.confirmed || plan.revision !== revision) throw changed();
  const chips = await planSources(db, user, plan.input);
  // Revision can change text and camera directions; voice identities remain the reviewed choices.
  validatePlan(script, plan.input, chips.map(chip => chip.id), plan.script.speakers.map(speaker => speaker.voice));
  const frames = await pruneFrames(deps.store ?? getObjectStore(), { script, frames: plan.frames });
  const [updated] = await db.update(podcastPlans).set({ script, frames, revision: revision + 1, updatedAt: (deps.now?.() ?? new Date()).getTime() }).where(and(
    eq(podcastPlans.id, id), eq(podcastPlans.ownerId, user), eq(podcastPlans.revision, revision), eq(podcastPlans.confirmed, false),
  )).returning();
  if (!updated) throw changed();
  return publicPodcastPlan(updated, { store: deps.store, storyboard: await storyboardEnabled(deps) });
}

/** Revises the plan from a chat request; the request and the model's reply join the plan's chat. */
export async function refinePodcastPlanChat(db: Database, user: string, id: string, revision: number, message: string, deps: ServiceDeps = {}) {
  const plan = await getPodcastPlan(db, user, id);
  if (plan.confirmed || plan.revision !== revision) throw changed();
  const chips = await planSources(db, user, plan.input);
  const ai = deps.ai ?? await getAiProvider();
  const charge = await reservePodcastPoints(user, `plan:${id}:chat:${randomUUID()}`, ai.podcastModelId(), deps.billingEnvironment);
  let cost = 0;
  try {
    const pricing = charge ? await ai.podcastPricing() : null;
    const refined = await ai.refinePodcastPlan({
      language: LANGUAGE_NAMES[plan.input.language], script: plan.script, request: message,
      chips: chips.map(chip => ({ id: chip.id, title: chip.title, summary: chip.summary, highlights: chip.highlights })),
      history: plan.messages.map(({ role, text }) => ({ role, text })),
    }, { abortSignal: AbortSignal.timeout(120_000), onUsage: usage => { if (pricing) cost += usageCostUsd(usage, pricing); } });
    const script = podcastPlanScriptSchema.parse(refined.script);
    validatePlan(script, plan.input, chips.map(chip => chip.id), plan.script.speakers.map(speaker => speaker.voice));
    const now = (deps.now?.() ?? new Date()).toISOString();
    const messages: PodcastPlanMessage[] = [...plan.messages,
      { id: randomUUID(), role: "user" as const, text: message, revision, createdAt: now },
      { id: randomUUID(), role: "assistant" as const, text: refined.reply, revision: revision + 1, createdAt: now }].slice(-MAX_PLAN_MESSAGES);
    const frames = await pruneFrames(deps.store ?? getObjectStore(), { script, frames: plan.frames });
    const [updated] = await db.update(podcastPlans).set({ script, frames, messages, revision: revision + 1, updatedAt: Date.parse(now) }).where(and(
      eq(podcastPlans.id, id), eq(podcastPlans.ownerId, user), eq(podcastPlans.revision, revision), eq(podcastPlans.confirmed, false),
    )).returning();
    if (!updated) throw changed();
    await charge?.settle(Math.max(1, pointsForCost(cost)), { plan: true, chat: true, textCostUsd: cost });
    return publicPodcastPlan(updated, { store: deps.store, storyboard: !!ai.storyboardImageModelId() });
  } catch (error) {
    await charge?.settle(0, { failed: true });
    if (error instanceof ApiError) throw error;
    console.error("[podcast-plan] refinement failed", error);
    throw new ApiError(502, "PODCAST_PLAN_REFINE_FAILED", "The plan could not be revised. Please try again.");
  }
}

/** Draws the storyboard frames the current revision is missing with `STORY_BOARD_IMAGE_MODEL`. */
export async function drawPodcastPlanFrames(db: Database, user: string, id: string, revision: number, deps: ServiceDeps = {}) {
  const plan = await getPodcastPlan(db, user, id);
  if (plan.confirmed || plan.revision !== revision) throw changed();
  const ai = deps.ai ?? await getAiProvider();
  const model = ai.storyboardImageModelId();
  if (!model) throw new ApiError(503, "PODCAST_STORYBOARD_UNAVAILABLE", "Storyboard frames are not available right now.");
  const store = deps.store ?? getObjectStore();
  const chips = await planSources(db, user, plan.input);
  const titles = new Map(chips.map(chip => [chip.id, chip.title]));
  const missing = new Map<string, PodcastPlanScript["segments"][number]>();
  for (const segment of plan.script.segments.slice(0, MAX_STORYBOARD_FRAMES)) {
    const hash = storyboardFrameHash(segment.camera);
    if (!plan.frames[hash] && !missing.has(hash)) missing.set(hash, segment);
  }
  if (!missing.size) return publicPodcastPlan(plan, { store, storyboard: true });
  const charge = await reservePodcastPoints(user, `plan:${id}:frames:${randomUUID()}`, model, deps.billingEnvironment);
  const drawn: Record<string, PodcastPlanFrame> = {};
  let attempts = 0;
  try {
    const deadline = AbortSignal.timeout(240_000);
    const queue = [...missing];
    await Promise.all(Array.from({ length: Math.min(FRAME_CONCURRENCY, queue.length) }, async () => {
      for (let next = queue.shift(); next && !deadline.aborted; next = queue.shift()) {
        const [hash, segment] = next;
        attempts += 1;
        try {
          const frame = await ai.drawStoryboardFrame({ camera: segment.camera, caption: segment.caption, chipTitle: titles.get(segment.chipId) ?? "",
            style: plan.input.videoStyle }, { abortSignal: deadline });
          const key = frameKey(user, id, hash);
          await store.put(key, { bytes: frame.png, contentType: "image/png", cacheControl: "private, max-age=31536000, immutable" });
          drawn[hash] = { key, width: frame.width, height: frame.height };
        } catch (error) {
          // One shot failing leaves it without a frame; the user can draw the missing ones again.
          console.warn("[podcast-plan] storyboard frame failed", { plan: id, message: (error instanceof Error ? error.message : String(error)).slice(0, 300) });
        }
      }
    }));
    // Content-keyed frames merge safely with a concurrent revision; pruning drops any it no longer uses.
    const latest = await getPodcastPlan(db, user, id);
    const frames = await pruneFrames(store, { script: latest.script, frames: { ...latest.frames, ...drawn } });
    const [updated] = await db.update(podcastPlans).set({ frames, updatedAt: (deps.now?.() ?? new Date()).getTime() }).where(and(eq(podcastPlans.id, id), eq(podcastPlans.ownerId, user))).returning();
    const cost = attempts * ai.storyboardImageUsdPerImage();
    await charge?.settle(Object.keys(drawn).length ? Math.max(1, pointsForCost(cost)) : 0, { plan: true, frames: Object.keys(drawn).length, imageCostUsd: cost });
    if (!Object.keys(drawn).length) throw new ApiError(502, "PODCAST_STORYBOARD_FAILED", "The storyboard frames could not be drawn. Please try again.");
    return publicPodcastPlan(updated, { store, storyboard: true });
  } catch (error) {
    if (!(error instanceof ApiError && error.code === "PODCAST_STORYBOARD_FAILED")) await charge?.settle(0, { failed: true });
    throw error;
  }
}

/** The owner's unconfirmed plans, most recently changed first, as the library lists them. */
export async function listPodcastPlans(db: Database, user: string, deps: ServiceDeps = {}) {
  const store = deps.store ?? getObjectStore();
  const plans = await db.select().from(podcastPlans).where(and(eq(podcastPlans.ownerId, user), eq(podcastPlans.confirmed, false)))
    .orderBy(desc(podcastPlans.updatedAt)).limit(50);
  return Promise.all(plans.map(async plan => {
    const cover = planFrames(plan).find(frame => frame);
    return { id: plan.id, revision: plan.revision, title: plan.script.title, summary: plan.script.summary ?? null,
      lineCount: plan.script.segments.length, library: !!plan.input.library, language: plan.input.language, day: plan.input.day,
      createdAt: new Date(plan.createdAt).toISOString(), updatedAt: new Date(plan.updatedAt).toISOString(),
      thumbnailUrl: cover ? (await store.signedGet(cover.key, { inline: true, expiresInSeconds: 3600 }).catch(() => null))?.url ?? null : null };
  }));
}

/** Discards an unconfirmed plan and its storyboard frames. Confirmed plans stay with the podcast they made. */
export async function deletePodcastPlan(db: Database, user: string, id: string, deps: ServiceDeps = {}) {
  const plan = await getPodcastPlan(db, user, id);
  if (plan.confirmed) throw new ApiError(409, "PODCAST_PLAN_CONFIRMED", "This plan was confirmed and is part of its podcast.");
  const deleted = await db.delete(podcastPlans).where(and(eq(podcastPlans.id, id), eq(podcastPlans.ownerId, user),
    eq(podcastPlans.confirmed, false), lt(podcastPlans.generatingUntil, Date.now()))).returning({ id: podcastPlans.id });
  if (!deleted.length) throw new ApiError(409, "PODCAST_PLAN_GENERATING", "This plan is generating and can't be deleted now.");
  const store = deps.store ?? getObjectStore();
  await Promise.all(Object.values(plan.frames).map(frame => store.delete(frame.key).catch(() => undefined)));
}

export async function confirmPodcastPlan(db: Database, user: string, id: string, revision: number, deps: ServiceDeps = {},
  onProgress?: Parameters<typeof createDailyPodcast>[4]) {
  let plan = await getPodcastPlan(db, user, id);
  if (plan.revision !== revision) throw changed();
  await planSources(db, user, plan.input);
  if (!plan.confirmed) {
    const [confirmed] = await db.update(podcastPlans).set({ confirmed: true }).where(and(
      eq(podcastPlans.id, id), eq(podcastPlans.ownerId, user), eq(podcastPlans.revision, revision), eq(podcastPlans.confirmed, false),
    )).returning();
    if (!confirmed) {
      plan = await getPodcastPlan(db, user, id);
      if (!plan.confirmed || plan.revision !== revision) throw changed();
    } else { plan = confirmed; }
  }
  // Fence concurrent confirmations across server instances before any media or billing calls.
  const now = Date.now();
  const lease = now + 330_000;
  const claimed = await db.update(podcastPlans).set({ generatingUntil: lease }).where(and(
    eq(podcastPlans.id, id), eq(podcastPlans.ownerId, user), lt(podcastPlans.generatingUntil, now),
  )).returning();
  if (!claimed.length) throw new ApiError(409, "PODCAST_PLAN_GENERATING", "This plan is already generating. Try again shortly to retrieve the saved podcast.");
  try {
    return await createDailyPodcast(db, user, plan.input, { ...deps, approvedPlan: { id, script: plan.script, frames: planFrames(plan) } }, onProgress);
  } finally {
    await db.update(podcastPlans).set({ generatingUntil: 0 }).where(and(eq(podcastPlans.id, id), eq(podcastPlans.generatingUntil, lease)));
  }
}
