import { createHash } from "node:crypto";
import { and, asc, eq, isNull, lte, or } from "drizzle-orm";
import type { Database } from "@/lib/db/client";
import { pushDevices, summaries, todoLists, todoNotifications as events, todoNotificationDeliveries as receipts } from "@/lib/db/schema";
import { apnsConfigured, sendPush } from "@/lib/notifications/apns";
import { isDeadToken } from "./notifications";

/** Durable outbox: failed APNs deliveries retry on the next cron; accepted installations are skipped. */
export async function deliverTodoNotifications(db: Database, now = new Date()) {
  if (!apnsConfigured()) return { todoNotifications: 0 };
  const pending = await db.select().from(events).where(and(eq(events.delivered, false), lte(events.dueAt, now), or(isNull(events.leaseUntil), lte(events.leaseUntil, now))))
    .orderBy(asc(events.dueAt)).limit(25);
  let count = 0;
  for (const event of pending) {
    const runnerId = crypto.randomUUID();
    const claim = await db.update(events).set({ runnerId, leaseUntil: new Date(now.getTime() + 10 * 60_000) })
      .where(and(eq(events.id, event.id), eq(events.delivered, false), or(isNull(events.leaseUntil), lte(events.leaseUntil, now))));
    if (!claim.rowsAffected) continue;
    const owned = () => and(eq(events.id, event.id), eq(events.runnerId, runnerId));
    let failed = false;
    try {
      const devices = await db.select().from(pushDevices).innerJoin(summaries, eq(summaries.ownerId, pushDevices.ownerId)).where(eq(summaries.id, event.summaryId));
      const delivered = await db.select().from(receipts).where(eq(receipts.eventId, event.id));
      const sent = new Set(delivered.map((row) => `${row.ownerId}:${row.installationId}`));
      const unsent = devices.filter(({ push_devices: device }) => !sent.has(`${device.ownerId}:${device.installationId}`));
      // Bound fan-out. Remaining installations continue from their receipts on the next cron.
      if (unsent.length > 20) failed = true;
      // Recheck the current document before each delivery; completion/rescheduling invalidates old events.
      for (const { push_devices: device } of unsent.slice(0, 20)) {
        const [current] = await db.select({ document: todoLists.document, ownerId: summaries.ownerId }).from(todoLists)
          .innerJoin(summaries, eq(summaries.id, todoLists.summaryId)).where(eq(todoLists.summaryId, event.summaryId));
        if (!current) break;
        const item = current.document.items.find((item) => item.id === event.itemId);
        const valid = event.kind === "created" || (event.itemId
          ? item && !item.completed && new Date(item.deadline).getTime() === event.dueAt.getTime()
          : current.document.items.some((item) => !item.completed) && new Date(current.document.deadline).getTime() === event.dueAt.getTime());
        if (!valid) break;
        if (device.ownerId !== current.ownerId) continue;
        const [registered] = await db.select().from(pushDevices).where(and(eq(pushDevices.installationId, device.installationId), eq(pushDevices.ownerId, device.ownerId), eq(pushDevices.token, device.token)));
        if (!registered) continue;
        const result = await sendPush(device, {
          aps: { alert: { title: event.kind === "created" ? "AI created a todo list" : "Todo deadline reached",
            body: (item ? `${current.document.title}: ${item.title}` : current.document.title).slice(0, 180) }, sound: "default" },
          summaryId: event.summaryId, userId: current.ownerId,
        }, { collapseId: createHash("sha256").update(event.id).digest("hex") });
        if (isDeadToken(result)) {
          await db.delete(pushDevices).where(and(eq(pushDevices.installationId, device.installationId), eq(pushDevices.token, device.token), eq(pushDevices.ownerId, device.ownerId), eq(pushDevices.updatedAt, device.updatedAt)));
        } else if (result.status !== 200) { failed = true; continue; }
        await db.insert(receipts).values({ eventId: event.id, installationId: device.installationId, ownerId: device.ownerId }).onConflictDoNothing();
      }
      if (!failed) {
        await db.update(events).set({ delivered: true, runnerId: null, leaseUntil: null }).where(owned());
        count += 1;
      }
    } catch { failed = true; }
    if (failed) await db.update(events).set({ runnerId: null, leaseUntil: null }).where(owned());
  }
  return { todoNotifications: count };
}
