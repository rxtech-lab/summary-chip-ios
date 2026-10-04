import { and, eq } from "drizzle-orm";
import type { Database } from "@/lib/db/client";
import { pushDevices, type SummaryRow } from "@/lib/db/schema";
import { apnsConfigured, sendPush, type PushPayload } from "@/lib/notifications/apns";

/** Called after persistence, in `after()`. Delivery never changes the creation response. */
export async function notifySummaryAdded(db: Database, summary: Pick<SummaryRow, "id" | "ownerId" | "title">): Promise<void> {
  if (!apnsConfigured()) return;
  const devices = await db.select().from(pushDevices).where(eq(pushDevices.ownerId, summary.ownerId));
  const payload: PushPayload = {
    aps: { alert: { title: "Summary added", body: [...summary.title].slice(0, 180).join("") }, sound: "default" },
    summaryId: summary.id,
    userId: summary.ownerId,
  };
  // Bound simultaneous connections for accounts with many installations.
  for (let offset = 0; offset < devices.length; offset += 10) {
    await Promise.all(devices.slice(offset, offset + 10).map(async (device) => {
      try {
        const result = await sendPush(device, payload);
        if (result.status === 410 || (result.status === 400 && ["BadDeviceToken", "DeviceTokenNotForTopic"].includes(result.reason ?? ""))) {
          // Don't delete a registration refreshed or reassigned during delivery.
          await db.delete(pushDevices).where(and(eq(pushDevices.installationId, device.installationId), eq(pushDevices.ownerId, device.ownerId), eq(pushDevices.token, device.token), eq(pushDevices.updatedAt, device.updatedAt)));
        } else if (result.status !== 200) {
          console.warn("[notifications] APNs rejected delivery", { status: result.status, reason: result.reason });
        }
      } catch {
        console.warn("[notifications] push delivery failed");
      }
    }));
  }
}
