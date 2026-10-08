import { describe, expect, it } from "vitest";
import { tripDocumentSchema } from "@/lib/contracts/trip";
import {
  assessNowcast,
  conditionForCode,
  conditionOf,
  dayAheadAlertText,
  detectNowcastEvent,
  nowcastAlertText,
  type Nowcast,
  type NowcastAlertState,
} from "@/lib/weather/conditions";
import { parseOpenMeteo, OpenMeteoProvider } from "@/lib/weather/open-meteo";
import { WeatherProviderError, type DailyForecast, type NowcastSlot } from "@/lib/weather/provider";
import { dayAheadTimes, HOUR, inNowcastWindow, isTimeZone, localParts, MINUTE, nowcastDate, planNextCheck, zonedTime, type WeatherSchedule } from "@/lib/weather/schedule";
import { nowcastLocation, tripLocations, tripZones } from "@/lib/services/weather";

const TOKYO = { startDate: "2026-10-12", endDate: "2026-10-14", timeZone: "Asia/Tokyo" };
/** 2026-10-12 12:00 in Tokyo. */
const noon = Date.parse("2026-10-12T03:00:00Z");

describe("time zones", () => {
  it("converts trip wall-clock times both ways", () => {
    expect(zonedTime("2026-10-11", 20 * 60, "Asia/Tokyo")).toBe(Date.parse("2026-10-11T11:00:00Z"));
    expect(localParts(noon, "Asia/Tokyo")).toEqual({ date: "2026-10-12", minutes: 12 * 60 });
    // Across a DST change (New York, 2026-11-01).
    expect(zonedTime("2026-11-01", 20 * 60, "America/New_York")).toBe(Date.parse("2026-11-02T01:00:00Z"));
    expect(zonedTime("2026-10-31", 20 * 60, "America/New_York")).toBe(Date.parse("2026-11-01T00:00:00Z"));
  });

  it("falls back to UTC for an unknown zone", () => {
    expect(localParts(noon, "Not/AZone")).toEqual({ date: "2026-10-12", minutes: 3 * 60 });
  });
});

describe("weather schedule", () => {
  it("sends tomorrow's weather at 20:00 the evening before each day", () => {
    expect(dayAheadTimes(TOKYO).map(({ date, at, until }) => ({ date, at, until }))).toEqual([
      { date: "2026-10-12", at: Date.parse("2026-10-11T11:00:00Z"), until: Date.parse("2026-10-11T15:00:00Z") },
      { date: "2026-10-13", at: Date.parse("2026-10-12T11:00:00Z"), until: Date.parse("2026-10-12T15:00:00Z") },
      { date: "2026-10-14", at: Date.parse("2026-10-13T11:00:00Z"), until: Date.parse("2026-10-13T15:00:00Z") },
    ]);
  });

  it("checks daily far ahead, every 3 hours in forecast range and every 15 minutes during the trip's daytime", () => {
    const farAhead = Date.parse("2026-09-01T00:00:00Z");
    expect(planNextCheck(TOKYO, farAhead).nextAt - farAhead).toBe(24 * HOUR);
    const weekBefore = Date.parse("2026-10-05T03:00:00Z");
    expect(planNextCheck(TOKYO, weekBefore).nextAt - weekBefore).toBe(3 * HOUR);
    expect(planNextCheck(TOKYO, noon).nextAt - noon).toBe(15 * MINUTE);
    expect(inNowcastWindow(TOKYO, noon)).toBe(true);
  });

  it("wakes for the day-ahead alert and the first morning check", () => {
    // 2026-10-11 18:30 Tokyo: three-hour interval cut short by 20:00.
    const evening = Date.parse("2026-10-11T09:30:00Z");
    expect(planNextCheck(TOKYO, evening).nextAt).toBe(Date.parse("2026-10-11T11:00:00Z"));
    // 2026-10-12 23:00 Tokyo: night, the forecast still refreshes every 3 hours.
    const night = Date.parse("2026-10-12T14:00:00Z");
    expect(inNowcastWindow(TOKYO, night)).toBe(false);
    expect(planNextCheck(TOKYO, night).nextAt - night).toBe(3 * HOUR);
    // 2026-10-13 05:30 Tokyo: the first nowcast check is at 07:00.
    expect(planNextCheck(TOKYO, Date.parse("2026-10-12T20:30:00Z")).nextAt).toBe(Date.parse("2026-10-12T22:00:00Z"));
  });

  it("follows the traveller across time zones", () => {
    // Home in New York; day 1 in Tokyo, day 2 flies Tokyo → London, day 3 in London.
    const trip: WeatherSchedule = {
      ...TOKYO,
      homeZone: "America/New_York",
      zones: {
        "2026-10-12": { morning: "Asia/Tokyo", evening: "Asia/Tokyo" },
        "2026-10-13": { morning: "Asia/Tokyo", evening: "Europe/London" },
        "2026-10-14": { morning: "Europe/London", evening: "Europe/London" },
      },
    };
    expect(dayAheadTimes(trip).map(({ date, at, timeZone }) => ({ date, at, timeZone }))).toEqual([
      // 20:00 at home the evening before leaving.
      { date: "2026-10-12", at: Date.parse("2026-10-11T20:00:00-04:00"), timeZone: "America/New_York" },
      // 20:00 where each evening is spent.
      { date: "2026-10-13", at: Date.parse("2026-10-12T20:00:00+09:00"), timeZone: "Asia/Tokyo" },
      { date: "2026-10-14", at: Date.parse("2026-10-13T20:00:00+01:00"), timeZone: "Europe/London" },
    ]);
    // The travel day is watched from 07:00 in Tokyo until 22:00 in London.
    expect(nowcastDate(trip, Date.parse("2026-10-13T07:30:00+09:00"))).toBe("2026-10-13");
    expect(nowcastDate(trip, Date.parse("2026-10-13T21:00:00+01:00"))).toBe("2026-10-13");
    expect(nowcastDate(trip, Date.parse("2026-10-13T22:30:00+01:00"))).toBeNull();
    // Day 3 starts at 07:00 London time, not Tokyo time.
    expect(nowcastDate(trip, Date.parse("2026-10-14T06:30:00+01:00"))).toBeNull();
    expect(planNextCheck(trip, Date.parse("2026-10-14T06:30:00+01:00")).nextAt).toBe(Date.parse("2026-10-14T07:00:00+01:00"));
    // Over at midnight in London, not in Tokyo.
    expect(planNextCheck(trip, Date.parse("2026-10-14T23:30:00+01:00")).done).toBe(false);
    expect(planNextCheck(trip, Date.parse("2026-10-15T00:00:00+01:00")).done).toBe(true);
  });

  it("validates zone names", () => {
    expect(isTimeZone("Asia/Tokyo")).toBe(true);
    expect(isTimeZone("Mars/Olympus")).toBe(false);
  });

  it("stops once the trip is over", () => {
    expect(planNextCheck(TOKYO, Date.parse("2026-10-14T15:00:00Z")).done).toBe(true);
    expect(planNextCheck(TOKYO, Date.parse("2026-10-14T14:00:00Z")).done).toBe(false);
  });
});

describe("conditions", () => {
  it("maps WMO codes and strong gusts", () => {
    expect(conditionForCode(0)).toBe("clear");
    expect(conditionForCode(61)).toBe("rain");
    expect(conditionForCode(82)).toBe("heavy_rain");
    expect(conditionForCode(75)).toBe("heavy_snow");
    expect(conditionForCode(96)).toBe("thunderstorm");
    expect(conditionOf({ code: 2, gusts: 70 })).toBe("strong_wind");
    expect(conditionOf({ code: 95, gusts: 70 })).toBe("thunderstorm");
  });
});

const slot = (minutesFromNoon: number, code: number): NowcastSlot => {
  const at = noon + minutesFromNoon * MINUTE;
  const local = new Date(at + 9 * HOUR).toISOString().slice(0, 16);
  return { at, local, code, temperature: 18, precipitation: code >= 61 ? 1.2 : 0, gusts: 10 };
};

describe("next 30 minutes", () => {
  it("finds bad weather arriving within the window and when it starts", () => {
    const nowcast = assessNowcast([slot(0, 1), slot(15, 3), slot(30, 63), slot(45, 63)], null, noon + 2 * MINUTE)!;
    expect(nowcast.current.condition).toBe("clear");
    expect(nowcast.upcoming).toEqual({ condition: "rain", at: noon + 30 * MINUTE, local: "2026-10-12T12:30" });
  });

  it("ignores slots beyond 30 minutes", () => {
    const nowcast = assessNowcast([slot(0, 1), slot(15, 1), slot(30, 1), slot(45, 95)], null, noon + 2 * MINUTE)!;
    expect(nowcast.upcoming.condition).toBe("clear");
  });

  it("reports rain stopping", () => {
    const nowcast = assessNowcast([slot(0, 63), slot(15, 63), slot(30, 2)], null, noon + 2 * MINUTE)!;
    expect(nowcast.current.condition).toBe("rain");
    expect(nowcast.upcoming).toMatchObject({ condition: "partly_cloudy", at: noon + 30 * MINUTE });
  });

  const where = { date: "2026-10-12", placeKey: "35.01,135.77" };
  const nowcast = (current: Nowcast["current"]["condition"], upcoming: Nowcast["upcoming"]["condition"]): Nowcast => ({
    current: { condition: current, temperature: 18 }, upcoming: { condition: upcoming, at: noon + 20 * MINUTE, local: "2026-10-12T12:20" },
  });

  it("alerts when it turns bad, gets worse, changes and clears — once each", () => {
    let state: NowcastAlertState | null = null;
    let at = noon;
    const step = (current: Nowcast["current"]["condition"], upcoming: Nowcast["upcoming"]["condition"]) => {
      at += 30 * MINUTE;
      const result = detectNowcastEvent(state, nowcast(current, upcoming), where, at);
      state = result.state;
      return result.event?.kind ?? null;
    };
    expect(step("clear", "cloudy")).toBeNull();
    expect(step("cloudy", "drizzle")).toBeNull();
    expect(step("cloudy", "rain")).toBe("starts");
    expect(step("rain", "rain")).toBeNull();
    expect(step("rain", "heavy_rain")).toBe("worsens");
    expect(step("heavy_rain", "rain")).toBeNull();
    expect(step("rain", "heavy_snow")).toBe("changes");
    expect(step("heavy_snow", "cloudy")).toBe("clears");
    expect(step("cloudy", "clear")).toBeNull();
  });

  it("announces bad weather already there, and starts over for a new place or day", () => {
    const first = detectNowcastEvent(null, nowcast("rain", "rain"), where, noon);
    expect(first.event).toEqual({ kind: "now", condition: "rain" });
    expect(detectNowcastEvent(first.state, nowcast("rain", "rain"), where, noon + HOUR).event).toBeNull();
    expect(detectNowcastEvent(first.state, nowcast("rain", "rain"), { ...where, placeKey: "34.69,135.50" }, noon + HOUR).event?.kind).toBe("now");
    expect(detectNowcastEvent(first.state, nowcast("rain", "rain"), { ...where, date: "2026-10-13" }, noon + HOUR).event?.kind).toBe("now");
  });

  it("holds alerts back for 20 minutes, except a thunderstorm", () => {
    const first = detectNowcastEvent(null, nowcast("clear", "rain"), where, noon);
    const held = detectNowcastEvent(first.state, nowcast("rain", "heavy_rain"), where, noon + 5 * MINUTE);
    expect(held.event).toBeNull();
    expect(held.state).toEqual(first.state);
    expect(detectNowcastEvent(first.state, nowcast("rain", "thunderstorm"), where, noon + 5 * MINUTE).event?.kind).toBe("worsens");
  });

  it("writes alerts in the trip's language", () => {
    expect(nowcastAlertText({ kind: "starts", condition: "rain", local: "2026-10-12T12:30" }, "Kyoto", "en"))
      .toEqual({ title: "Rain soon in Kyoto", body: "Rain expected from 12:30. Plan for shelter or cover." });
    expect(nowcastAlertText({ kind: "clears", from: "rain", local: "2026-10-12T12:30" }, "京都", "zh-Hant").title).toBe("京都雨將停");
  });
});

const day = (overrides: Partial<DailyForecast> = {}): DailyForecast => ({
  date: "2026-10-13", code: 63, high: 21.4, low: 14.2, precipitationChance: 80, precipitation: 6, windMax: 20, gustsMax: 35, uvIndexMax: 3,
  sunrise: "2026-10-13T05:50", sunset: "2026-10-13T17:20", ...overrides,
});

describe("tomorrow's weather", () => {
  it("summarizes each place with a tip", () => {
    expect(dayAheadAlertText([{ place: "Kyoto", forecast: day() }, { place: "Nara", forecast: day({ code: 3, precipitationChance: 10, high: 22, low: 15 }) }], "en")).toEqual({
      title: "Tomorrow in Kyoto: Rain",
      body: "Kyoto: Rain, 14–21°C, 80% chance of rain · Nara: Cloudy, 15–22°C. Bring an umbrella.",
    });
    expect(dayAheadAlertText([{ place: "京都", forecast: day() }], "zh-Hans")).toEqual({
      title: "明天京都：雨",
      body: "京都：雨，14–21°C，降水概率 80%。记得带伞。",
    });
  });
});

describe("trip locations", () => {
  const document = tripDocumentSchema.parse({
    title: "Kansai", startDate: "2026-10-12", endDate: "2026-10-14", timeZone: "Asia/Tokyo",
    places: [
      { id: "kyoto", name: "Kyoto Station", kind: "station", major: true, coordinate: { lat: 34.9858, lng: 135.7588 } },
      { id: "kiyomizu", name: "Kiyomizu-dera", coordinate: { lat: 34.9949, lng: 135.785 } },
      { id: "nara", name: "Nara Park", coordinate: { lat: 34.685, lng: 135.843 } },
      { id: "hotel-place", name: "Hotel Kyoto", kind: "hotel", coordinate: { lat: 35.0, lng: 135.76 } },
    ],
    hotels: [{ id: "hotel", name: "Hotel Kyoto", placeId: "hotel-place", checkIn: "2026-10-12", checkOut: "2026-10-14" }],
    days: [
      { id: "d1", date: "2026-10-12", title: "Kyoto", route: { kind: "side", placeIds: ["kyoto", "kiyomizu"] }, stayId: "hotel" },
      { id: "d2", date: "2026-10-13", title: "Nara", moments: [
        { slot: "morning", time: "09:00", text: "Train", placeId: "kyoto" },
        { slot: "afternoon", time: "13:00", text: "Deer", placeId: "nara" },
      ] },
      { id: "d3", date: "2026-10-14", title: "Rest" },
    ],
  });

  it("picks each day's distinct places, falling back to where the traveller slept", () => {
    const entries = tripLocations(document);
    expect(entries.map((entry) => [entry.dayId, entry.locations.map((location) => location.placeId)])).toEqual([
      ["d1", ["kyoto"]],
      ["d2", ["kyoto", "nara"]],
      ["d3", ["nara"]],
    ]);
    expect(entries[0].locations[0].key).toBe("34.99,135.76");
  });

  it("follows the day's moments for the next 30 minutes, at each place's local time", () => {
    const entries = tripLocations(document);
    const tokyoTime = () => "Asia/Tokyo";
    expect(nowcastLocation(document, entries, "2026-10-13", Date.parse("2026-10-13T10:00:00+09:00"), tokyoTime)?.placeId).toBe("kyoto");
    expect(nowcastLocation(document, entries, "2026-10-13", Date.parse("2026-10-13T12:40:00+09:00"), tokyoTime)?.placeId).toBe("nara");
    expect(nowcastLocation(document, entries, "2026-10-20", Date.parse("2026-10-20T12:00:00+09:00"), tokyoTime)).toBeNull();
    // Were Nara an hour behind, its 13:00 would still be ahead at 12:40 Tokyo time.
    const naraBehind = (location: { placeId: string | null }) => location.placeId === "nara" ? "Asia/Shanghai" : "Asia/Tokyo";
    expect(nowcastLocation(document, entries, "2026-10-13", Date.parse("2026-10-13T12:40:00+09:00"), naraBehind)?.placeId).toBe("kyoto");
  });

  it("takes each date's morning and night zones from its first and last places", () => {
    const zone = (location: { placeId: string | null }) => location.placeId === "nara" ? "Asia/Shanghai" : "Asia/Tokyo";
    expect(tripZones(tripLocations(document), zone)).toEqual({
      "2026-10-12": { morning: "Asia/Tokyo", evening: "Asia/Tokyo" },
      "2026-10-13": { morning: "Asia/Tokyo", evening: "Asia/Shanghai" },
      "2026-10-14": { morning: "Asia/Shanghai", evening: "Asia/Shanghai" },
    });
  });
});

describe("Open-Meteo", () => {
  const answer = {
    utc_offset_seconds: 32400, timezone: "Asia/Tokyo",
    current: { time: "2026-10-12T12:00", weather_code: 3, temperature_2m: 19.5, precipitation: 0, wind_gusts_10m: 14 },
    daily: {
      time: ["2026-10-12"], weather_code: [61], temperature_2m_max: [21], temperature_2m_min: [14], precipitation_probability_max: [70],
      precipitation_sum: [4.2], wind_speed_10m_max: [18], wind_gusts_10m_max: [33], uv_index_max: [4], sunrise: ["2026-10-12T05:49"], sunset: ["2026-10-12T17:21"],
    },
    minutely_15: { time: ["2026-10-12T12:00", "2026-10-12T12:15"], weather_code: [3, 61], temperature_2m: [19.5, 19], precipitation: [0, 0.4], wind_gusts_10m: [14, 20] },
  };

  it("normalizes an answer, converting local times with the UTC offset", () => {
    const parsed = parseOpenMeteo(answer);
    expect(parsed.current).toEqual({ at: noon, code: 3, temperature: 19.5, precipitation: 0, gusts: 14 });
    expect(parsed.daily[0]).toMatchObject({ date: "2026-10-12", code: 61, high: 21, low: 14, precipitationChance: 70 });
    expect(parsed.nowcast[1]).toEqual({ at: noon + 15 * MINUTE, local: "2026-10-12T12:15", code: 61, temperature: 19, precipitation: 0.4, gusts: 20 });
  });

  it("asks once for several places and reads the array answer", async () => {
    const urls: string[] = [];
    const provider = new OpenMeteoProvider({ fetch: async (input) => { urls.push(String(input)); return Response.json([answer, answer]); } });
    expect(await provider.forecast([{ lat: 35, lng: 135.7 }, { lat: 34.6, lng: 135.8 }])).toHaveLength(2);
    const url = new URL(urls[0]);
    expect(url.origin).toBe("https://api.open-meteo.com");
    expect(url.searchParams.get("latitude")).toBe("35.0000,34.6000");
    expect(url.searchParams.get("timezone")).toBe("auto");
  });

  it("uses the customer host with a key and reports rate limits", async () => {
    const provider = new OpenMeteoProvider({ key: "k", fetch: async (input) => {
      expect(String(input)).toContain("https://customer-api.open-meteo.com/v1/forecast?");
      expect(String(input)).toContain("apikey=k");
      return new Response("{}", { status: 429, headers: { "retry-after": "120" } });
    } });
    const failure = await provider.forecast([{ lat: 35, lng: 135 }]).catch((error) => error);
    expect(failure).toBeInstanceOf(WeatherProviderError);
    expect(failure.retryAfterMs).toBe(120_000);
  });
});
