import { createHash } from "node:crypto";
import { and, asc, eq, gte, inArray, isNotNull, isNull, lte, or } from "drizzle-orm";
import type { Database } from "@/lib/db/client";
import { pushDevices, summaries, summaryViews, tripReminderBriefings as briefings, tripReminderDeliveries as deliveries, tripReminderSchedules as schedules, trips, type SummaryRow } from "@/lib/db/schema";
import { getAiProvider } from "@/lib/ai/provider";
import { tripBriefingBodySchema, tripBriefingInput, type TripBriefingInput } from "@/lib/ai/trip-briefing-agent";
import { apnsConfigured, sendPush } from "@/lib/notifications/apns";
import { getTripReminderScheduler, tripReminders, type TripReminder } from "@/lib/trips/reminders";
import { dayAheadAlertText, type DayAheadLine } from "@/lib/weather/conditions";
import { addDays, DAY, MINUTE } from "@/lib/weather/schedule";
import { isDeadToken, tripReminderPayload } from "./notifications";
import { canViewerRead, readableByViewer } from "./share-access";
import { activeTripDocument } from "./trip-document";
import { findPlanSelections, withStoredDefaults } from "./trips";
import { translationLanguageFor } from "./translations";
import { tripBriefingWeather } from "./weather";

const LEASE_MS = 10 * MINUTE;
const FAN_OUT_LIMIT = 20;
const BRIEFINGS_PER_STEP = 3;
type ReminderPlan = { done: true } | { done: false; nextAt: number };

const inputHash = (input: TripBriefingInput) => createHash("sha256").update(JSON.stringify(input)).digest("hex");

async function readableRecipient(db: Database, summary: SummaryRow, userId: string, now: Date): Promise<boolean> {
  if (summary.ownerId === userId) return true;
  const [view] = await db.select({ id: summaryViews.summaryId }).from(summaryViews)
    .where(and(eq(summaryViews.summaryId, summary.id), eq(summaryViews.userId, userId)));
  return Boolean(view && await canViewerRead(db, summary, userId, now));
}

async function briefingBody(db: Database, tripId: string, input: TripBriefingInput, reminder: TripReminder, weather: DayAheadLine[], canGenerate: boolean) {
  const hash = inputHash(input);
  const [cached] = await db.select().from(briefings).where(and(eq(briefings.tripId, tripId), eq(briefings.inputHash, hash)));
  if (cached) return { body: cached.body, generated: false };
  if (!canGenerate) return null;
  const weatherText = weather.length ? dayAheadAlertText(weather.slice(0, 2), translationLanguageFor(input.language)).body : "";
  const fallback = [...(weatherText ? `${[...reminder.detail].slice(0, 50).join("")} · ${weatherText}` : reminder.detail)].slice(0, 140).join("");
  let body = fallback;
  try {
    const parsed = tripBriefingBodySchema.safeParse(await (await getAiProvider()).briefTripDay(input));
    if (parsed.success) body = parsed.data;
    else console.warn("[trip-reminders] invalid agent briefing; using saved itinerary");
  } catch {
    console.warn("[trip-reminders] agent briefing failed; using saved itinerary");
  }
  await db.insert(briefings).values({ tripId, inputHash: hash, body, expiresAt: new Date(reminder.until) }).onConflictDoNothing();
  const [saved] = await db.select({ body: briefings.body }).from(briefings).where(and(eq(briefings.tripId, tripId), eq(briefings.inputHash, hash)));
  return { body: saved?.body ?? body, generated: true };
}

/** Called after creation or a document edit. Even a delayed hook reads the latest saved itinerary. */
export async function syncTripReminders(db: Database, tripId: string, now = new Date()): Promise<void> {
  const [trip] = await db.select({ id: trips.summaryId }).from(trips).where(eq(trips.summaryId, tripId));
  if (!trip) return;
  const runnerId = crypto.randomUUID();
  const values = { runnerId, nextAt: now, leaseUntil: new Date(now.getTime() + LEASE_MS) };
  await db.insert(schedules).values({ tripId, ...values }).onConflictDoUpdate({ target: schedules.tripId, set: values });
  await startRun(db, tripId, runnerId);
}

async function startRun(db: Database, tripId: string, runnerId: string): Promise<boolean> {
  try {
    await getTripReminderScheduler().start(tripId, runnerId);
    return true;
  } catch {
    // Leave the schedule durable and recoverable by the existing five-minute notification cron.
    await db.update(schedules).set({ leaseUntil: null }).where(and(eq(schedules.tripId, tripId), eq(schedules.runnerId, runnerId)));
    console.warn("[trip-reminders] workflow start failed");
    return false;
  }
}

async function saveNextCheck(db: Database, tripId: string, runnerId: string, nextAt: number | null): Promise<ReminderPlan> {
  const result = await db.update(schedules).set({
    nextAt: nextAt === null ? null : new Date(nextAt),
    // A missed wake-up must be recoverable before a ten-minute leg reminder expires.
    leaseUntil: nextAt === null ? null : new Date(nextAt + MINUTE),
  }).where(and(eq(schedules.tripId, tripId), eq(schedules.runnerId, runnerId)));
  return nextAt === null || !result.rowsAffected ? { done: true } : { done: false, nextAt };
}

/** One bounded delivery step; every wake-up uses current sharing, plan selections and device ownership. */
export async function refreshTripReminders(db: Database, tripId: string, runnerId: string, at?: Date): Promise<ReminderPlan> {
  try {
    return await sendScheduledReminders(db, tripId, runnerId, at);
  } catch (error) {
    // If step retries are exhausted, cron can still recover within the reminder's delivery window.
    await db.update(schedules).set({ leaseUntil: new Date((at ?? new Date()).getTime() + MINUTE) })
      .where(and(eq(schedules.tripId, tripId), eq(schedules.runnerId, runnerId)));
    throw error;
  }
}

async function sendScheduledReminders(db: Database, tripId: string, runnerId: string, at?: Date): Promise<ReminderPlan> {
  const now = at ?? new Date();
  const claimed = await db.update(schedules).set({ leaseUntil: new Date(now.getTime() + LEASE_MS) })
    .where(and(eq(schedules.tripId, tripId), eq(schedules.runnerId, runnerId), isNotNull(schedules.nextAt)));
  if (!claimed.rowsAffected) return { done: true };
  const [found] = await db.select({ summary: summaries, trip: trips }).from(trips)
    .innerJoin(summaries, eq(summaries.id, trips.summaryId)).where(eq(trips.summaryId, tripId));
  if (!found) return { done: true };
  const document = withStoredDefaults(found.trip.document);
  // Include every plan option's times so a reader switching plans never needs a new workflow.
  const events = tripReminders(document);
  const due = events.filter((event) => event.at <= now.getTime() && event.until > now.getTime())
    .sort((a, b) => a.kind === b.kind ? a.at - b.at : a.kind === "leg" ? -1 : 1);
  const future = events.filter((event) => event.at > now.getTime());
  if (due.length && apnsConfigured()) {
    const viewers = await db.select({ userId: summaryViews.userId }).from(summaryViews)
      .innerJoin(summaries, eq(summaries.id, summaryViews.summaryId))
      .where(and(eq(summaryViews.summaryId, tripId), readableByViewer(summaryViews.userId, now)));
    const recipients = [...new Set([found.summary.ownerId, ...viewers.map((viewer) => viewer.userId)])];
    const devices = await db.select().from(pushDevices).where(inArray(pushDevices.ownerId, recipients));
    const receipts = await db.select().from(deliveries).where(and(eq(deliveries.tripId, tripId), inArray(deliveries.eventKey, due.map((event) => event.key))));
    const receiptKey = (key: string, installationId: string, userId: string) => JSON.stringify([key, installationId, userId]);
    const sent = new Set(receipts.map((receipt) => receiptKey(receipt.eventKey, receipt.installationId, receipt.userId)));
    let count = 0;
    let generatedBriefings = 0;
    // Deliver due departures to all installations before any slower agent generation.
    for (const event of due) {
      for (const device of devices) {
        const key = receiptKey(event.key, device.installationId, device.ownerId);
        if (sent.has(key)) continue;
        if (count >= FAN_OUT_LIMIT) return saveNextCheck(db, tripId, runnerId, now.getTime() + 1000);
        // A save, revoked share, plan switch or sign-out while earlier devices were sent takes effect here.
        const [current] = await db.select({ summary: summaries, trip: trips, runnerId: schedules.runnerId }).from(trips)
          .innerJoin(summaries, eq(summaries.id, trips.summaryId))
          .innerJoin(schedules, eq(schedules.tripId, trips.summaryId)).where(eq(trips.summaryId, tripId));
        if (!current || current.runnerId !== runnerId) return { done: true };
        const clock = at ?? new Date();
        if (!await readableRecipient(db, current.summary, device.ownerId, clock)) continue;
        const active = activeTripDocument(withStoredDefaults(current.trip.document), await findPlanSelections(db, current.trip, device.ownerId));
        const reminder = tripReminders(active).find((item) => item.key === event.key);
        if (!reminder || reminder.at > clock.getTime() || reminder.until <= clock.getTime()) continue;
        let message = reminder;
        if (reminder.kind === "day") {
          const weather = await tripBriefingWeather(db, tripId, active, reminder.date, clock.getTime());
          const input = tripBriefingInput(active, reminder.date, current.summary.language, weather);
          const briefing = await briefingBody(db, tripId, input, reminder, weather, generatedBriefings < BRIEFINGS_PER_STEP);
          if (!briefing) return saveNextCheck(db, tripId, runnerId, (at ?? new Date()).getTime() + 1000);
          if (briefing.generated) generatedBriefings += 1;
          // Agent generation is asynchronous: do not send a stale plan or forecast after it finishes.
          const [latest] = await db.select({ summary: summaries, trip: trips, runnerId: schedules.runnerId }).from(trips)
            .innerJoin(summaries, eq(summaries.id, trips.summaryId))
            .innerJoin(schedules, eq(schedules.tripId, trips.summaryId)).where(eq(trips.summaryId, tripId));
          if (!latest || latest.runnerId !== runnerId) return { done: true };
          const afterGeneration = at ?? new Date();
          if (!await readableRecipient(db, latest.summary, device.ownerId, afterGeneration)) continue;
          const selected = activeTripDocument(withStoredDefaults(latest.trip.document), await findPlanSelections(db, latest.trip, device.ownerId));
          const updatedWeather = await tripBriefingWeather(db, tripId, selected, reminder.date, afterGeneration.getTime());
          if (latest.trip.revision !== current.trip.revision || inputHash(tripBriefingInput(selected, reminder.date, latest.summary.language, updatedWeather)) !== inputHash(input)) {
            return saveNextCheck(db, tripId, runnerId, afterGeneration.getTime() + 1000);
          }
          message = { ...reminder, detail: briefing.body };
        }
        if (reminder.until <= (at ?? new Date()).getTime()) continue;
        const [registered] = await db.select().from(pushDevices).where(and(eq(pushDevices.installationId, device.installationId), eq(pushDevices.ownerId, device.ownerId), eq(pushDevices.token, device.token)));
        if (!registered) continue;
        const result = await sendPush(registered, tripReminderPayload(device.ownerId, tripId, active.title, message, current.summary.language), {
          collapseId: createHash("sha256").update(JSON.stringify([tripId, event.key])).digest("hex"),
          expiration: Math.floor(reminder.until / 1000),
        });
        if (isDeadToken(result)) {
          await db.delete(pushDevices).where(and(eq(pushDevices.installationId, registered.installationId), eq(pushDevices.ownerId, registered.ownerId), eq(pushDevices.token, registered.token), eq(pushDevices.updatedAt, registered.updatedAt)));
        } else if (result.status !== 200) {
          // Workflow retries; receipts for earlier successful installations survive.
          throw new Error(`Trip reminder rejected by APNs (${result.status})`);
        }
        await db.insert(deliveries).values({ tripId, eventKey: event.key, installationId: device.installationId, userId: device.ownerId }).onConflictDoNothing();
        sent.add(key);
        count += 1;
      }
    }
  }
  // A daily wake-up also lets abandoned runs recover and bounds the duration of a lease.
  const nextAt = future.length ? Math.min(now.getTime() + DAY, future[0].at) : null;
  return saveNextCheck(db, tripId, runnerId, nextAt);
}

/** Backfills existing upcoming trips and recovers interrupted starts or expired workflow leases. */
export async function resumeTripReminders(db: Database, now = new Date()): Promise<{ remindersRestarted: number }> {
  await db.delete(briefings).where(lte(briefings.expiresAt, now));
  const missing = await db.select({ id: trips.summaryId }).from(trips)
    .leftJoin(schedules, eq(schedules.tripId, trips.summaryId))
    // One day of slack covers trips still in progress west of UTC.
    .where(and(isNull(schedules.tripId), gte(trips.endDate, addDays(now.toISOString().slice(0, 10), -1))))
    .orderBy(asc(trips.startDate)).limit(100);
  for (const trip of missing) {
    await db.insert(schedules).values({ tripId: trip.id, runnerId: crypto.randomUUID(), nextAt: now }).onConflictDoNothing();
  }
  const overdue = await db.select().from(schedules)
    .where(and(lte(schedules.nextAt, now), or(isNull(schedules.leaseUntil), lte(schedules.leaseUntil, now))))
    .orderBy(asc(schedules.nextAt)).limit(100);
  let remindersRestarted = 0;
  for (const schedule of overdue) {
    const runnerId = crypto.randomUUID();
    const claimed = await db.update(schedules).set({ runnerId, leaseUntil: new Date(now.getTime() + LEASE_MS) })
      .where(and(eq(schedules.tripId, schedule.tripId), eq(schedules.runnerId, schedule.runnerId), lte(schedules.nextAt, now), or(isNull(schedules.leaseUntil), lte(schedules.leaseUntil, now))));
    if (claimed.rowsAffected && await startRun(db, schedule.tripId, runnerId)) remindersRestarted += 1;
  }
  return { remindersRestarted };
}
