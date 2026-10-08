import type { TranslationLanguage } from "@/lib/contracts/api";
import type { CurrentWeather, DailyForecast, NowcastSlot } from "./provider";

/** Weather in a handful of kinds the apps show and alerts talk about. Spec: `docs/weather.md`. */

export const CONDITIONS = [
  "clear", "partly_cloudy", "cloudy", "fog", "drizzle", "rain", "heavy_rain", "freezing_rain",
  "snow", "heavy_snow", "thunderstorm", "strong_wind",
] as const;
export type Condition = (typeof CONDITIONS)[number];

/** 0 fine · 1 a nuisance · 2 bad (rain, snow, gales) · 3 heavy · 4 thunderstorm. */
const SEVERITY: Record<Condition, number> = {
  clear: 0, partly_cloudy: 0, cloudy: 0, fog: 1, drizzle: 1,
  rain: 2, snow: 2, strong_wind: 2, heavy_rain: 3, freezing_rain: 3, heavy_snow: 3, thunderstorm: 4,
};

/** Alerts start at this severity: "bad weather". */
export const BAD = 2;
/** Gusts from this speed (km/h) count as strong wind. */
export const STRONG_GUSTS_KMH = 60;

export function severity(condition: Condition): number {
  return SEVERITY[condition];
}

/** WMO weather interpretation code → condition. */
export function conditionForCode(code: number): Condition {
  if (code <= 1) return "clear";
  if (code === 2) return "partly_cloudy";
  if (code === 3) return "cloudy";
  if (code === 45 || code === 48) return "fog";
  if (code >= 51 && code <= 55) return "drizzle";
  if (code === 56 || code === 57 || code === 66 || code === 67) return "freezing_rain";
  if (code === 61 || code === 63 || code === 80 || code === 81) return "rain";
  if (code === 65 || code === 82) return "heavy_rain";
  if (code === 71 || code === 73 || code === 77 || code === 85) return "snow";
  if (code === 75 || code === 86) return "heavy_snow";
  if (code >= 95) return "thunderstorm";
  return "cloudy";
}

/** The code's condition, or strong wind when the gusts are worse than it. */
export function conditionOf(weather: { code: number; gusts: number | null }): Condition {
  const condition = conditionForCode(weather.code);
  return (weather.gusts ?? 0) >= STRONG_GUSTS_KMH && severity(condition) < severity("strong_wind") ? "strong_wind" : condition;
}

export function dailyCondition(day: DailyForecast): Condition {
  return conditionOf({ code: day.code, gusts: day.gustsMax });
}

/* ------------------------------------------------------------------------------------------------
 * The next 30 minutes
 * ---------------------------------------------------------------------------------------------- */

export const NOWCAST_WINDOW_MS = 30 * 60_000;
const SLOT_MS = 15 * 60_000;

export interface Nowcast {
  /** Right now: the running 15-minute slot, else the provider's current conditions. */
  current: { condition: Condition; temperature: number | null };
  /** The worst weather starting within the next 30 minutes, and when it starts. */
  upcoming: { condition: Condition; at: number; local: string };
}

export function assessNowcast(slots: NowcastSlot[], current: CurrentWeather | null, now: number): Nowcast | null {
  const running = slots.find((slot) => slot.at <= now && now < slot.at + SLOT_MS);
  const ahead = slots.filter((slot) => slot.at > now && slot.at <= now + NOWCAST_WINDOW_MS);
  const nowWeather = running ?? current;
  if (!nowWeather || (!running && !ahead.length)) return null;
  const currentCondition = conditionOf(nowWeather);
  let upcoming = { condition: currentCondition, at: now, local: running?.local ?? "" };
  for (const slot of ahead) {
    const condition = conditionOf(slot);
    if (severity(condition) > severity(upcoming.condition) || (severity(upcoming.condition) < BAD && severity(condition) >= BAD)) {
      upcoming = { condition, at: slot.at, local: slot.local };
    }
  }
  // Nothing worse ahead: report the weather the window ends with (e.g. the rain stopping).
  if (upcoming.condition === currentCondition && ahead.length) {
    const last = ahead[ahead.length - 1];
    if (severity(conditionOf(last)) < BAD && severity(currentCondition) >= BAD) {
      const firstDry = ahead.find((slot) => severity(conditionOf(slot)) < BAD)!;
      upcoming = { condition: conditionOf(last), at: firstDry.at, local: firstDry.local };
    }
  }
  return { current: { condition: currentCondition, temperature: nowWeather.temperature }, upcoming };
}

/** What the last nowcast alert said, so the next check only alerts on a real change. */
export interface NowcastAlertState {
  /** Trip-local date and the place it was about; a new day or place starts over. */
  date: string;
  placeKey: string;
  /** The bad weather last announced, or null when nothing bad is announced. */
  announced: Condition | null;
  /** When the last alert was sent (Unix ms). */
  alertedAt: number | null;
}

export type NowcastEvent =
  | { kind: "now"; condition: Condition }
  | { kind: "starts"; condition: Condition; local: string }
  | { kind: "worsens"; condition: Condition; local: string }
  | { kind: "changes"; from: Condition; condition: Condition; local: string }
  | { kind: "clears"; from: Condition; local: string };

/** Alerts about the same place come at most this often (a thunderstorm always gets through). */
export const NOWCAST_MIN_GAP_MS = 20 * 60_000;

/**
 * Decides whether the next 30 minutes deserve an alert: bad weather arriving (or already there,
 * unannounced), getting worse, turning into another kind of bad weather, or clearing up after an
 * announced spell. Returns the state to store (unchanged when an alert is held back).
 */
export function detectNowcastEvent(
  previous: NowcastAlertState | null,
  nowcast: Nowcast,
  where: { date: string; placeKey: string },
  now: number,
): { event: NowcastEvent | null; state: NowcastAlertState } {
  const same = previous && previous.date === where.date && previous.placeKey === where.placeKey;
  const state: NowcastAlertState = same ? previous : { ...where, announced: null, alertedAt: null };
  const { current, upcoming } = nowcast;
  const ahead = upcoming.condition;
  let event: NowcastEvent | null = null;
  if (!state.announced) {
    if (severity(current.condition) >= BAD && severity(current.condition) >= severity(ahead)) event = { kind: "now", condition: current.condition };
    else if (severity(ahead) >= BAD) event = { kind: "starts", condition: ahead, local: upcoming.local };
  } else if (severity(ahead) > severity(state.announced)) {
    event = { kind: "worsens", condition: ahead, local: upcoming.local };
  } else if (severity(ahead) >= BAD && severity(ahead) === severity(state.announced) && ahead !== state.announced) {
    event = { kind: "changes", from: state.announced, condition: ahead, local: upcoming.local };
  } else if (severity(ahead) < BAD) {
    // Over now, or stopping within the half hour.
    event = { kind: "clears", from: state.announced, local: upcoming.local };
  }
  if (!event) return { event: null, state };
  const urgent = event.kind !== "clears" && event.condition === "thunderstorm";
  if (state.alertedAt !== null && now - state.alertedAt < NOWCAST_MIN_GAP_MS && !urgent) return { event: null, state };
  return { event, state: { ...state, announced: event.kind === "clears" ? null : event.condition, alertedAt: now } };
}

/* ------------------------------------------------------------------------------------------------
 * Alert texts, in the trip's language (the apps ship en, zh-Hans and zh-Hant).
 * ---------------------------------------------------------------------------------------------- */

type AlertLanguage = "en" | "zh-Hans" | "zh-Hant";

function alertLanguage(language: TranslationLanguage | null): AlertLanguage {
  return language === "zh-Hans" || language === "zh-Hant" ? language : "en";
}

function clock(local: string): string {
  return local.length >= 16 ? local.slice(11, 16) : "";
}

function degrees(value: number | null): string {
  return value === null ? "" : `${Math.round(value)}°C`;
}

const NAMES: Record<AlertLanguage, Record<Condition, string>> = {
  en: {
    clear: "Clear", partly_cloudy: "Partly cloudy", cloudy: "Cloudy", fog: "Fog", drizzle: "Drizzle", rain: "Rain",
    heavy_rain: "Heavy rain", freezing_rain: "Freezing rain", snow: "Snow", heavy_snow: "Heavy snow", thunderstorm: "Thunderstorm", strong_wind: "Strong wind",
  },
  "zh-Hans": {
    clear: "晴", partly_cloudy: "多云", cloudy: "阴", fog: "雾", drizzle: "毛毛雨", rain: "雨",
    heavy_rain: "大雨", freezing_rain: "冻雨", snow: "雪", heavy_snow: "大雪", thunderstorm: "雷雨", strong_wind: "大风",
  },
  "zh-Hant": {
    clear: "晴", partly_cloudy: "多雲", cloudy: "陰", fog: "霧", drizzle: "毛毛雨", rain: "雨",
    heavy_rain: "大雨", freezing_rain: "凍雨", snow: "雪", heavy_snow: "大雪", thunderstorm: "雷雨", strong_wind: "強風",
  },
};

export function conditionName(condition: Condition, language: TranslationLanguage | null): string {
  return NAMES[alertLanguage(language)][condition];
}

interface NowTexts {
  now: (name: string, place: string) => [string, string];
  starts: (name: string, place: string, time: string) => [string, string];
  worsens: (name: string, place: string, time: string) => [string, string];
  changes: (from: string, name: string, place: string, time: string) => [string, string];
  clears: (from: string, place: string, time: string) => [string, string];
}

const NOW_TEXTS: Record<AlertLanguage, NowTexts> = {
  en: {
    now: (name, place) => [`${name} in ${place}`, "It's coming down now and will keep on for the next half hour."],
    starts: (name, place, time) => [`${name} soon in ${place}`, `${name} expected${time ? ` from ${time}` : " within 30 minutes"}. Plan for shelter or cover.`],
    worsens: (name, place, time) => [`${name} soon in ${place}`, `Getting worse${time ? ` from ${time}` : " within 30 minutes"}.`],
    changes: (from, name, place, time) => [`${name} soon in ${place}`, `${from} turning to ${name.toLowerCase()}${time ? ` around ${time}` : ""}.`],
    clears: (from, place, time) => [`${from} easing in ${place}`, `Clearing up${time ? ` by ${time}` : " within 30 minutes"}.`],
  },
  "zh-Hans": {
    now: (name, place) => [`${place}正在下${name}`, "未来半小时仍将持续。"],
    starts: (name, place, time) => [`${place}即将${name}`, `预计${time ? ` ${time} 起` : "30 分钟内"}有${name}，请做好准备。`],
    worsens: (name, place, time) => [`${place}即将${name}`, `天气转差${time ? `，${time} 起` : "，30 分钟内"}。`],
    changes: (from, name, place, time) => [`${place}即将${name}`, `${from}将转为${name}${time ? `（约 ${time}）` : ""}。`],
    clears: (from, place, time) => [`${place}${from}将停`, `${time ? `约 ${time} ` : "30 分钟内"}转好。`],
  },
  "zh-Hant": {
    now: (name, place) => [`${place}正在下${name}`, "未來半小時仍會持續。"],
    starts: (name, place, time) => [`${place}即將${name}`, `預計${time ? ` ${time} 起` : "30 分鐘內"}有${name}，請做好準備。`],
    worsens: (name, place, time) => [`${place}即將${name}`, `天氣轉差${time ? `，${time} 起` : "，30 分鐘內"}。`],
    changes: (from, name, place, time) => [`${place}即將${name}`, `${from}將轉為${name}${time ? `（約 ${time}）` : ""}。`],
    clears: (from, place, time) => [`${place}${from}將停`, `${time ? `約 ${time} ` : "30 分鐘內"}轉好。`],
  },
};

export function nowcastAlertText(event: NowcastEvent, place: string, language: TranslationLanguage | null): { title: string; body: string } {
  const lang = alertLanguage(language);
  const texts = NOW_TEXTS[lang];
  const names = NAMES[lang];
  let parts: [string, string];
  switch (event.kind) {
    case "now": parts = texts.now(names[event.condition], place); break;
    case "starts": parts = texts.starts(names[event.condition], place, clock(event.local)); break;
    case "worsens": parts = texts.worsens(names[event.condition], place, clock(event.local)); break;
    case "changes": parts = texts.changes(names[event.from], names[event.condition], place, clock(event.local)); break;
    case "clears": parts = texts.clears(names[event.from], place, clock(event.local)); break;
  }
  return { title: parts[0], body: parts[1] };
}

/* ------------------------------------------------------------------------------------------------
 * Tomorrow's weather
 * ---------------------------------------------------------------------------------------------- */

export interface DayAheadLine {
  place: string;
  forecast: DailyForecast;
}

const DAY_AHEAD: Record<AlertLanguage, {
  title: (place: string, name: string) => string;
  line: (place: string, name: string, range: string, chance: string) => string;
  chance: (percent: number) => string;
  umbrella: string;
  wind: string;
  heat: string;
  uv: string;
}> = {
  en: {
    title: (place, name) => `Tomorrow in ${place}: ${name}`,
    line: (place, name, range, chance) => [`${place}: ${name}`, range, chance].filter(Boolean).join(", "),
    chance: (percent) => `${percent}% chance of rain`,
    umbrella: "Bring an umbrella.",
    wind: "Expect strong gusts.",
    heat: "It'll be hot; stay hydrated.",
    uv: "High UV; wear sunscreen.",
  },
  "zh-Hans": {
    title: (place, name) => `明天${place}：${name}`,
    line: (place, name, range, chance) => [`${place}：${name}`, range, chance].filter(Boolean).join("，"),
    chance: (percent) => `降水概率 ${percent}%`,
    umbrella: "记得带伞。",
    wind: "注意大风。",
    heat: "天气炎热，注意补水。",
    uv: "紫外线强，注意防晒。",
  },
  "zh-Hant": {
    title: (place, name) => `明天${place}：${name}`,
    line: (place, name, range, chance) => [`${place}：${name}`, range, chance].filter(Boolean).join("，"),
    chance: (percent) => `降雨機率 ${percent}%`,
    umbrella: "記得帶傘。",
    wind: "注意強風。",
    heat: "天氣炎熱，注意補充水分。",
    uv: "紫外線強，注意防曬。",
  },
};

/** "Tomorrow in Kyoto: Rain" / "Kyoto: Rain, 14–21°C, 80% chance of rain · Osaka: …  Bring an umbrella." */
export function dayAheadAlertText(lines: DayAheadLine[], language: TranslationLanguage | null): { title: string; body: string } {
  const lang = alertLanguage(language);
  const texts = DAY_AHEAD[lang];
  const names = NAMES[lang];
  const first = lines[0];
  const body = lines.map(({ place, forecast }) => {
    const range = forecast.low !== null && forecast.high !== null ? `${Math.round(forecast.low)}–${degrees(forecast.high)}` : degrees(forecast.high);
    const chance = (forecast.precipitationChance ?? 0) >= 20 ? texts.chance(Math.round(forecast.precipitationChance!)) : "";
    return texts.line(place, names[dailyCondition(forecast)], range, chance);
  }).join(" · ");
  const tips: string[] = [];
  const all = lines.map((line) => line.forecast);
  const wet = (day: DailyForecast) => (day.precipitationChance ?? 0) >= 50 || ["drizzle", "rain", "heavy_rain", "freezing_rain", "thunderstorm"].includes(dailyCondition(day));
  if (all.some(wet)) tips.push(texts.umbrella);
  if (all.some((day) => (day.gustsMax ?? 0) >= STRONG_GUSTS_KMH)) tips.push(texts.wind);
  if (all.some((day) => (day.high ?? 0) >= 32)) tips.push(texts.heat);
  else if (all.some((day) => (day.uvIndexMax ?? 0) >= 8)) tips.push(texts.uv);
  const separator = lang === "en" ? " " : "";
  return {
    title: texts.title(first.place, names[dailyCondition(first.forecast)]),
    body: [`${body}${lang === "en" ? "." : "。"}`, ...tips.slice(0, 2)].join(separator),
  };
}
