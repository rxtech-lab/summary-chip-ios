import type { FlightAlertState } from "@/lib/db/schema";
import type { TranslationLanguage } from "@/lib/contracts/api";
import type { ProviderFlight } from "./provider";
import { delayMinutes, isAirborne } from "./schedule";

/** What changed between two refreshes of a flight, worth a push. */
export type FlightEvent =
  | { kind: "time_change"; delayMinutes: number; departsLocal: string | null }
  | { kind: "gate"; terminal: string | null; gate: string | null }
  | { kind: "check_in"; desk: string | null }
  | { kind: "boarding"; gate: string | null }
  | { kind: "departed" }
  | { kind: "landed"; gate: string | null; belt: string | null }
  | { kind: "belt"; belt: string }
  | { kind: "cancelled" }
  | { kind: "diverted" };

/** A delay is announced at 15 minutes, and again whenever it moves by 15 more (either way). */
const DELAY_STEP = 15;

function hasLeft(flight: ProviderFlight): boolean {
  return isAirborne(flight.status) || flight.status === "landed" || flight.status === "diverted";
}

export function detectFlightEvents(
  previous: ProviderFlight,
  next: ProviderFlight,
  alertState: FlightAlertState | null,
): { events: FlightEvent[]; alertState: FlightAlertState } {
  const events: FlightEvent[] = [];
  const announced = alertState?.delayMinutes ?? 0;
  const delay = delayMinutes(next.departure) ?? 0;
  let nextState: FlightAlertState = { delayMinutes: announced };

  if (next.status === "cancelled" && previous.status !== "cancelled") {
    return { events: [{ kind: "cancelled" }], alertState: nextState };
  }
  if (next.status === "diverted" && previous.status !== "diverted") events.push({ kind: "diverted" });

  if (!hasLeft(next)) {
    if (Math.abs(delay - announced) >= DELAY_STEP) {
      events.push({ kind: "time_change", delayMinutes: delay, departsLocal: next.departure.estimatedLocal ?? next.departure.scheduledLocal });
      nextState = { delayMinutes: delay };
    }
    const gate = next.departure.gate;
    const terminal = next.departure.terminal;
    if ((gate && gate !== previous.departure.gate) || (terminal && previous.departure.terminal && terminal !== previous.departure.terminal)) {
      events.push({ kind: "gate", terminal, gate });
    }
    if (next.status === "check_in" && previous.status !== "check_in") events.push({ kind: "check_in", desk: next.departure.checkInDesk });
    if (next.status === "boarding" && previous.status !== "boarding") events.push({ kind: "boarding", gate });
  } else {
    if (isAirborne(next.status) && !hasLeft(previous)) events.push({ kind: "departed" });
    const belt = next.arrival.baggageBelt;
    if (next.status === "landed" && previous.status !== "landed") {
      events.push({ kind: "landed", gate: next.arrival.gate, belt });
    } else if (belt && belt !== previous.arrival.baggageBelt) {
      events.push({ kind: "belt", belt });
    }
  }
  return { events, alertState: nextState };
}

/* ------------------------------------------------------------------------------------------------
 * Alert texts, in the trip's language (the apps ship en, zh-Hans and zh-Hant).
 * ---------------------------------------------------------------------------------------------- */

type AlertLanguage = "en" | "zh-Hans" | "zh-Hant";

function alertLanguage(language: TranslationLanguage | null): AlertLanguage {
  return language === "zh-Hans" || language === "zh-Hant" ? language : "en";
}

function clock(local: string | null): string {
  return local ? local.slice(11, 16) : "";
}

function signedMinutes(minutes: number): string {
  return minutes > 0 ? `+${minutes}` : `${minutes}`;
}

interface Texts {
  delayed: (minutes: number, time: string, from: string) => [string, string];
  earlier: (minutes: number, time: string, from: string) => [string, string];
  onTime: (time: string, from: string) => [string, string];
  gate: (terminal: string | null, gate: string | null) => [string, string];
  checkIn: (desk: string | null) => [string, string];
  boarding: (gate: string | null) => [string, string];
  departed: (to: string, time: string) => [string, string];
  landed: (to: string, gate: string | null, belt: string | null) => [string, string];
  belt: (belt: string) => [string, string];
  cancelled: () => [string, string];
  diverted: () => [string, string];
}

const TEXTS: Record<AlertLanguage, Texts> = {
  en: {
    delayed: (m, t, from) => ["delayed", `Now departs ${t} (${signedMinutes(m)} min) from ${from}`],
    earlier: (m, t, from) => ["leaves earlier", `Now departs ${t} (${signedMinutes(m)} min) from ${from}`],
    onTime: (t, from) => ["back on time", `Departs ${t} from ${from}`],
    gate: (terminal, gate) => ["gate update", [terminal && `Terminal ${terminal}`, gate && `Gate ${gate}`].filter(Boolean).join(" · ")],
    checkIn: (desk) => ["check-in open", desk ? `Check-in desks ${desk}` : "Check-in is open"],
    boarding: (gate) => ["boarding", gate ? `Boarding now at gate ${gate}` : "Boarding now"],
    departed: (to, t) => ["departed", t ? `On the way to ${to}, arriving ${t}` : `On the way to ${to}`],
    landed: (to, gate, belt) => ["landed", [`Landed in ${to}`, gate && `gate ${gate}`, belt && `baggage belt ${belt}`].filter(Boolean).join(" · ")],
    belt: (belt) => ["baggage belt", `Your bags arrive at belt ${belt}`],
    cancelled: () => ["cancelled", "This flight has been cancelled. Check with your airline."],
    diverted: () => ["diverted", "This flight has been diverted. Check with your airline."],
  },
  "zh-Hans": {
    delayed: (m, t, from) => ["延误", `改为 ${t} 从${from}起飞（${signedMinutes(m)} 分钟）`],
    earlier: (m, t, from) => ["提前起飞", `改为 ${t} 从${from}起飞（${signedMinutes(m)} 分钟）`],
    onTime: (t, from) => ["恢复准点", `${t} 从${from}起飞`],
    gate: (terminal, gate) => ["登机口更新", [terminal && `${terminal} 号航站楼`, gate && `${gate} 号登机口`].filter(Boolean).join(" · ")],
    checkIn: (desk) => ["开始值机", desk ? `值机柜台 ${desk}` : "现已开始值机"],
    boarding: (gate) => ["开始登机", gate ? `请前往 ${gate} 号登机口登机` : "现已开始登机"],
    departed: (to, t) => ["已起飞", t ? `正飞往${to}，预计 ${t} 到达` : `正飞往${to}`],
    landed: (to, gate, belt) => ["已落地", [`已抵达${to}`, gate && `${gate} 号登机口`, belt && `${belt} 号行李转盘`].filter(Boolean).join(" · ")],
    belt: (belt) => ["行李转盘", `请在 ${belt} 号转盘提取行李`],
    cancelled: () => ["已取消", "该航班已取消，请联系航空公司。"],
    diverted: () => ["已备降", "该航班已备降，请联系航空公司。"],
  },
  "zh-Hant": {
    delayed: (m, t, from) => ["延誤", `改為 ${t} 從${from}起飛（${signedMinutes(m)} 分鐘）`],
    earlier: (m, t, from) => ["提前起飛", `改為 ${t} 從${from}起飛（${signedMinutes(m)} 分鐘）`],
    onTime: (t, from) => ["恢復準點", `${t} 從${from}起飛`],
    gate: (terminal, gate) => ["登機門更新", [terminal && `第 ${terminal} 航廈`, gate && `${gate} 號登機門`].filter(Boolean).join(" · ")],
    checkIn: (desk) => ["開始報到", desk ? `報到櫃檯 ${desk}` : "現已開始報到"],
    boarding: (gate) => ["開始登機", gate ? `請前往 ${gate} 號登機門登機` : "現已開始登機"],
    departed: (to, t) => ["已起飛", t ? `正飛往${to}，預計 ${t} 抵達` : `正飛往${to}`],
    landed: (to, gate, belt) => ["已降落", [`已抵達${to}`, gate && `${gate} 號登機門`, belt && `${belt} 號行李轉盤`].filter(Boolean).join(" · ")],
    belt: (belt) => ["行李轉盤", `請至 ${belt} 號轉盤提領行李`],
    cancelled: () => ["已取消", "此航班已取消，請聯絡航空公司。"],
    diverted: () => ["已轉降", "此航班已轉降，請聯絡航空公司。"],
  },
};

/** The alert for one event: the title starts with the flight number ("CX 520 delayed"). */
export function flightAlertText(event: FlightEvent, flight: ProviderFlight, language: TranslationLanguage | null): { title: string; body: string } {
  const texts = TEXTS[alertLanguage(language)];
  const from = flight.departure.iata ?? flight.departure.name;
  const to = flight.arrival.city ?? flight.arrival.name;
  let parts: [string, string];
  switch (event.kind) {
    case "time_change": {
      const time = clock(event.departsLocal);
      parts = event.delayMinutes >= DELAY_STEP ? texts.delayed(event.delayMinutes, time, from)
        : event.delayMinutes <= -DELAY_STEP ? texts.earlier(event.delayMinutes, time, from)
        : texts.onTime(time, from);
      break;
    }
    case "gate": parts = texts.gate(event.terminal, event.gate); break;
    case "check_in": parts = texts.checkIn(event.desk); break;
    case "boarding": parts = texts.boarding(event.gate); break;
    case "departed": parts = texts.departed(to, clock(flight.arrival.estimatedLocal ?? flight.arrival.scheduledLocal)); break;
    case "landed": parts = texts.landed(to, event.gate, event.belt); break;
    case "belt": parts = texts.belt(event.belt); break;
    case "cancelled": parts = texts.cancelled(); break;
    case "diverted": parts = texts.diverted(); break;
  }
  return { title: `${flight.flightNumber} ${parts[0]}`, body: parts[1] };
}
