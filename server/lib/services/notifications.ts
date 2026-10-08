import { and, eq } from "drizzle-orm";
import type { Database } from "@/lib/db/client";
import { pushDevices, type SummaryRow } from "@/lib/db/schema";
import { apnsConfigured, sendPush, type PushOptions, type PushPayload, type PushResult } from "@/lib/notifications/apns";
import { translationLanguageFor } from "./translations";
import type { TripReminder } from "@/lib/trips/reminders";

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

const TRIP_REMINDER_TITLES: Record<string, [day: string, leg: string]> = {
  en: ["Tomorrow's trip", "Your next leg starts now"],
  "zh-Hans": ["明日行程", "下一段行程现在出发"],
  "zh-Hant": ["明日行程", "下一段行程現在出發"],
  ja: ["明日の旅程", "次の移動の出発時刻です"],
  ko: ["내일의 여행 일정", "다음 구간이 지금 시작됩니다"],
  es: ["El viaje de mañana", "Tu próximo trayecto empieza ahora"],
  fr: ["Le voyage de demain", "Votre prochaine étape commence"],
  de: ["Die Reise morgen", "Deine nächste Etappe beginnt jetzt"],
};

export function tripReminderPayload(userId: string, tripId: string, title: string, reminder: TripReminder, language: string): PushPayload {
  const headings = TRIP_REMINDER_TITLES[translationLanguageFor(language) ?? "en"];
  return {
    aps: { alert: { title: headings[reminder.kind === "day" ? 0 : 1], body: clipAlert(`${clipAlert(title, 36)}: ${reminder.detail}`) }, sound: "default" },
    summaryId: tripId, tripId, userId,
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

const PAPER_CHANGED_TITLES: Record<string, [added: string, updated: string]> = {
  en: ["Paper added", "Paper updated"],
  "zh-Hans": ["论文已添加", "论文已更新"],
  "zh-Hant": ["論文已新增", "論文已更新"],
  ja: ["論文を追加しました", "論文を更新しました"],
  ko: ["논문이 추가되었습니다", "논문이 업데이트되었습니다"],
  es: ["Artículo añadido", "Artículo actualizado"],
  fr: ["Article ajouté", "Article mis à jour"],
  de: ["Paper hinzugefügt", "Paper aktualisiert"],
};

/** The debounced alert (`workflows/notify-paper-changes.ts`) after a paper is created or an agent edits it. */
export async function notifyPaperChanged(db: Database, paper: Pick<SummaryRow, "id" | "ownerId" | "title" | "language">, created: boolean): Promise<void> {
  const [added, updated] = PAPER_CHANGED_TITLES[translationLanguageFor(paper.language) ?? "en"] ?? PAPER_CHANGED_TITLES.en;
  await deliver(db, paper.ownerId, {
    aps: { alert: { title: created ? added : updated, body: clipAlert(paper.title) }, sound: "default" },
    summaryId: paper.id,
    paperId: paper.id,
    userId: paper.ownerId,
  }, { collapseId: `paper-update:${paper.id}` });
}

const REFERENCE_ERROR_TITLES: Record<string, string> = {
  en: "Reference check found problems",
  "zh-Hans": "参考文献检查发现问题",
  "zh-Hant": "參考文獻檢查發現問題",
  ja: "参考文献の確認で問題が見つかりました",
  ko: "참고문헌 검사에서 문제가 발견되었습니다",
  es: "La revisión de referencias encontró problemas",
  fr: "La vérification des références a trouvé des problèmes",
  de: "Die Quellenprüfung hat Probleme gefunden",
};

/** After a reference check run: the entries it found errors in, by key. Replaces the paper's previous one. */
export async function notifyReferenceErrors(db: Database, paper: Pick<SummaryRow, "id" | "ownerId" | "title" | "language">, keys: string[]): Promise<void> {
  if (!keys.length) return;
  const heading = REFERENCE_ERROR_TITLES[translationLanguageFor(paper.language) ?? "en"] ?? REFERENCE_ERROR_TITLES.en;
  await deliver(db, paper.ownerId, {
    aps: { alert: { title: heading, body: clipAlert(`${clipAlert(paper.title, 36)}: ${keys.join(", ")}`) }, sound: "default" },
    summaryId: paper.id,
    paperId: paper.id,
    userId: paper.ownerId,
  }, { collapseId: `paper-references:${paper.id}` });
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
