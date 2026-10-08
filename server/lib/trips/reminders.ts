import type { TripDocument } from "@/lib/contracts/trip";
import { addDays, isTimeZone, MINUTE, zonedTime } from "@/lib/weather/schedule";

export const TRIP_REMINDER_EVENING_MINUTES = 20 * 60;
export const LEG_REMINDER_WINDOW_MS = 10 * MINUTE;

export interface TripReminder {
  key: string;
  date: string;
  kind: "day" | "leg";
  at: number;
  until: number;
  detail: string;
}

function departureTime(value: string, zone: string): number {
  const [date, time] = value.split("T");
  const [hour, minute] = time.split(":").map(Number);
  return zonedTime(date, hour * 60 + minute, zone);
}

/** Pass the reader's active document for delivery; the full document supplies all wake-up times. */
export function tripReminders(document: TripDocument): TripReminder[] {
  const zone = isTimeZone(document.timeZone) ? document.timeZone : "UTC";
  const reminders: TripReminder[] = [];
  const transports = document.transports.filter((transport) => transport.status !== "idea");
  const dates = new Set([...document.days.map((day) => day.date), ...transports.map((transport) => transport.date)]);
  for (const date of [...dates].sort()) {
    if (date < document.startDate || date > document.endDate) continue;
    const days = document.days.filter((day) => day.date === date);
    const details = [
      ...days.map((day) => day.title),
      ...transports.filter((transport) => transport.date === date).map((transport) => {
        const option = transport.options.find((item) => item.id === transport.selectedOptionId) ?? transport.options[0];
        const departure = option?.departure ?? option?.segments[0]?.departure;
        return `${departure ? `${departure.slice(11)} ` : ""}${transport.label}`;
      }),
      ...days.flatMap((day) => day.moments.slice(0, 2).map((moment) => `${moment.time ? `${moment.time} ` : ""}${moment.text}`)),
    ];
    reminders.push({
      key: JSON.stringify(["day", date]), date, kind: "day",
      at: zonedTime(addDays(date, -1), TRIP_REMINDER_EVENING_MINUTES, zone),
      until: zonedTime(date, 0, zone),
      detail: `${date} · ${[...new Set(details)].slice(0, 4).join(" · ")}`,
    });
  }
  for (const transport of transports) {
    const option = transport.options.find((item) => item.id === transport.selectedOptionId) ?? transport.options[0];
    if (!option) continue;
    // Only the first segment can inherit the option's departure. Later untimed legs stay untimed.
    const legs = option.segments.length
      ? option.segments.map((segment, index) => ({
        departure: segment.departure ?? (index === 0 ? option.departure : null),
        label: `${segment.fromName} → ${segment.toName}`,
        service: segment.flight?.flightNumber ?? [segment.train?.name, segment.train?.number].filter(Boolean).join(" "),
      }))
      : [{ departure: option.departure, label: transport.label, service: option.label }];
    legs.forEach((leg, index) => {
      if (!leg.departure) return;
      const at = departureTime(leg.departure, zone);
      if (!Number.isFinite(at)) return;
      reminders.push({
        // Clock edits before departure reschedule this key; edits after delivery do not repeat it.
        key: JSON.stringify(["leg", transport.id, option.id, index, leg.departure.slice(0, 10)]),
        date: leg.departure.slice(0, 10),
        kind: "leg", at, until: at + LEG_REMINDER_WINDOW_MS,
        detail: `${leg.departure.slice(11)} ${leg.label}${leg.service ? ` · ${leg.service}` : ""}`,
      });
    });
  }
  return reminders.sort((a, b) => a.at - b.at || a.key.localeCompare(b.key));
}

/** Keeps the Workflow runtime out of services and local tests. */
export interface TripReminderScheduler {
  start(tripId: string, runnerId: string): Promise<void>;
}
let override: TripReminderScheduler | undefined;
export function setTripReminderSchedulerForTests(scheduler?: TripReminderScheduler): void { override = scheduler; }
export function getTripReminderScheduler(): TripReminderScheduler {
  return override ?? {
    async start(tripId, runnerId) {
      const [{ start }, { remindTrip }] = await Promise.all([import("workflow/api"), import("@/workflows/remind-trip")]);
      await start(remindTrip, [tripId, runnerId]);
    },
  };
}
