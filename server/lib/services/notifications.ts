import { and, eq } from "drizzle-orm";
import type { Database } from "@/lib/db/client";
import { pushDevices, type SummaryRow } from "@/lib/db/schema";
import { apnsConfigured, sendPush, type PushOptions, type PushPayload, type PushResult } from "@/lib/notifications/apns";
import { translationLanguageFor } from "./translations";

function clipAlert(text: string, max = 180): string {
  return [...text].slice(0, max).join("");
}

/** Called after persistence, in `after()`. Delivery never changes the creation response. */
export async function notifySummaryAdded(db: Database, summary: Pick<SummaryRow, "id" | "ownerId" | "title">): Promise<void> {
  await deliver(db, summary.ownerId, {
    aps: { alert: { title: "Summary added", body: clipAlert(summary.title) }, sound: "default" },
    summaryId: summary.id,
    userId: summary.ownerId,
  });
}

const TRIP_UPDATED_TITLES: Record<string, string> = {
  en: "Trip updated",
  "zh-Hans": "行程已更新",
  "zh-Hant": "行程已更新",
  ja: "旅程を更新しました",
  ko: "여행이 업데이트되었습니다",
  es: "Viaje actualizado",
  fr: "Voyage mis à jour",
  de: "Reise aktualisiert",
};

/** Recipient-specific account routing for the debounced workflow's trip update alert. */
export function tripUpdatedPayload(userId: string, tripId: string, title: string, changeSummary: string, language?: string | null): PushPayload {
  const heading = TRIP_UPDATED_TITLES[translationLanguageFor(language ?? "en") ?? "en"];
  return {
    aps: { alert: { title: heading, body: clipAlert(changeSummary.trim() ? `${clipAlert(title, 36)}: ${changeSummary.trim()}` : title) }, sound: "default" },
    summaryId: tripId,
    tripId,
    userId,
  };
}

const TRIP_TRANSLATED_TITLES: Record<string, [ready: string, failed: string]> = {
  en: ["Trip translated", "Trip not fully translated"],
  "zh-Hans": ["行程已翻译", "行程未能完整翻译"],
  "zh-Hant": ["行程已翻譯", "行程未能完整翻譯"],
  ja: ["旅程を翻訳しました", "旅程を翻訳しきれませんでした"],
  ko: ["여행을 번역했습니다", "여행을 모두 번역하지 못했습니다"],
  es: ["Viaje traducido", "No se pudo traducir todo el viaje"],
  fr: ["Voyage traduit", "Le voyage n'a pas pu être entièrement traduit"],
  de: ["Reise übersetzt", "Reise nicht vollständig übersetzt"],
};

/**
 * After a background trip translation (`workflows/translate-trip.ts`), in the language it was
 * translated into. `tripId` tells the app to refresh or open the trip view.
 */
export async function notifyTripTranslated(db: Database, userId: string, tripId: string, title: string, language: string, ready: boolean): Promise<void> {
  const [readyTitle, failedTitle] = TRIP_TRANSLATED_TITLES[translationLanguageFor(language) ?? "en"] ?? TRIP_TRANSLATED_TITLES.en;
  await deliver(db, userId, {
    aps: { alert: { title: ready ? readyTitle : failedTitle, body: clipAlert(title) }, sound: "default" },
    summaryId: tripId,
    tripId,
    userId,
  });
}

/** APNs answers that mean the token will never work again. */
export function isDeadToken(result: PushResult): boolean {
  return result.status === 410 || (result.status === 400 && ["BadDeviceToken", "DeviceTokenNotForTopic", "ExpiredToken"].includes(result.reason ?? ""));
}

/** Sends to every installation of the owner, removing registrations APNs reports as dead. */
export async function deliver(db: Database, ownerId: string, payload: PushPayload, options?: PushOptions): Promise<void> {
  if (!apnsConfigured()) return;
  const devices = await db.select().from(pushDevices).where(eq(pushDevices.ownerId, ownerId));
  // Bound simultaneous connections for accounts with many installations.
  for (let offset = 0; offset < devices.length; offset += 10) {
    await Promise.all(devices.slice(offset, offset + 10).map(async (device) => {
      try {
        const result = await (options ? sendPush(device, payload, options) : sendPush(device, payload));
        if (isDeadToken(result)) {
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
