/**
 * Converts the hand-built Northbound Japan trip (`northbound-japan-nextjs/data/*.json`) into a
 * standard TripDocument and writes it to `tests/fixtures/northbound-trip.json` (also the Swift
 * test fixture). Run from the server directory:
 *
 *   bun scripts/convert-northbound.ts [path/to/northbound-japan-nextjs/data]
 */
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { tripDocumentSchema, type TripDocument } from "../lib/contracts/trip";

type Point = [number, number];
interface Source { title: string; url: string }
interface MapStop { name: string; point: Point; days: number[]; dates: string; note: string; major: boolean }
interface MapRoute { kind: "out" | "side" | "back" | "ferry" | "airport" | "stay"; stops: string[]; points: Point[]; summary: string }
interface TripDay { n: number; short: string; title: string; route: string; stay: string; blurb: string; moments: string[]; transit: string; tip: string; date: string; highlight?: boolean }
interface Trip { intro: string; note: string; callout: string; days: TripDay[]; notes: { title: string; text: string }[]; sources: Source[] }
interface RailSegment { from: string; to: string; departure: string; arrival: string; train: string; trainNumber?: string; category: string; seating: string; price: string; sourceUrl: string }
interface RailOption { id: string; label: string; departure: string; arrival: string; duration: string; fare: string; fareAmount?: number; icFare?: number; warning?: string; segments: RailSegment[]; notes: string[]; sources: Source[] }
interface RailGroup { id: string; date: string; route: string; options: RailOption[] }
interface FareRow { id: string; date: string; route: string; note: string; fare: number; covered: boolean; optional?: boolean; mode?: string }
interface FareData { pass: { name: string; price: number; start: string; end: string }; rows: FareRow[]; optimized?: { title: string; text: string }; sources: Source[] }

const dataDir = process.argv[2] ?? path.join(process.env.HOME ?? "", "Downloads/northbound-japan-nextjs/data");
const read = <T>(file: string): T => JSON.parse(readFileSync(path.join(dataDir, file), "utf8")) as T;

const trip = read<Trip>("trip.json");
const stops = read<Record<string, MapStop>>("map-stops.json");
const routes = read<Record<string, MapRoute>>("map-routes.json");
const rail = read<{ groups: RailGroup[] }>("rail-data.json");
const fares = read<FareData>("fare-data.json");

const START = "2026-10-10";
const yen = (amount: number) => ({ amount, currency: "JPY" });
const clip = (text: string, max: number) => (text.length <= max ? text : `${text.slice(0, max - 1)}…`);

/** Day N of the trip as an ISO date (day 1 = 2026-10-10). */
function dateOfDay(n: number): string {
  const date = new Date(`${START}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + n - 1);
  return date.toISOString().slice(0, 10);
}

function addDays(iso: string, days: number): string {
  const date = new Date(`${iso}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}

/** "05:53" or "09:00 青森站" on `date` → "2026-10-12T05:53"; "待航班確認" → null. */
function localTime(date: string, text: string): string | null {
  const match = /^(\d{1,2}):(\d{2})/.exec(text.trim());
  return match ? `${date}T${match[1].padStart(2, "0")}:${match[2]}` : null;
}

/** The total ("…＝¥2,010") or else the first yen amount in a fare text ("成人單程紙票 ¥720；IC ¥715" → 720). */
function firstYen(text: string): number | null {
  const match = /[＝=]\s?[¥￥]\s?([\d,]+)/.exec(text) ?? /[¥￥]\s?([\d,]+)/.exec(text);
  return match ? Number(match[1].replaceAll(",", "")) : null;
}

/* Places ---------------------------------------------------------------------------------------- */

const places: TripDocument["places"] = Object.entries(stops).map(([id, stop]) => ({
  id,
  name: stop.name,
  kind: /机场|機場|空港|airport/i.test(stop.name) ? "airport" : "city",
  coordinate: { lat: stop.point[0], lng: stop.point[1] },
  address: null,
  note: [stop.dates, stop.note].filter(Boolean).join(" · "),
  photos: [],
  pricing: [],
  major: stop.major,
}));

/** Station names in the rail data (Traditional Chinese / Japanese) → place ids. */
const STATION_PLACES: Record<string, string> = {
  "千葉": "chiba", "京成千葉": "chiba", "東京": "tokyo", "仙台": "sendai", "松島海岸": "matsushima", "平泉": "hiraizumi",
  "盛岡": "morioka", "青森": "aomori", "弘前": "hirosaki", "函館": "hakodate", "函館站": "hakodate",
  "成田空港（T1）／空港第2ビル（T2・T3）": "narita",
};
/** Stay areas in the diary (Simplified Chinese) → place ids. */
const AREA_PLACES = Object.fromEntries(Object.entries(stops).map(([id, stop]) => [stop.name, id]));

/* Hotels: one per run of consecutive nights in the same area ------------------------------------ */

const hotels: TripDocument["hotels"] = [];
const stayOfDay = new Map<number, string>();
for (const day of trip.days) {
  const area = /^住\s*(.+?)(?:\s*·|$)/.exec(day.stay)?.[1]?.trim();
  if (!area) continue;
  const date = dateOfDay(day.n);
  const previous = hotels[hotels.length - 1];
  if (previous && previous.name === `${area}住宿（待定）` && previous.checkOut === date) {
    previous.checkOut = addDays(date, 1);
  } else {
    const placeId = AREA_PLACES[area] ?? null;
    hotels.push({
      id: `stay-${placeId ?? `area-${hotels.length + 1}`}-${date.slice(5).replace("-", "")}`,
      name: `${area}住宿（待定）`,
      placeId,
      address: null,
      checkIn: date,
      checkOut: addDays(date, 1),
      checkInTime: null,
      confirmation: null,
      price: null,
      url: null,
      status: "idea",
    });
  }
  stayOfDay.set(day.n, hotels[hotels.length - 1].id);
}

/* Transports ------------------------------------------------------------------------------------- */

type Segment = TripDocument["transports"][number]["options"][number]["segments"][number];
type TrainCategory = NonNullable<Segment["train"]>["category"];

function segmentMode(segment: RailSegment): Segment["mode"] {
  if (/渡輪|フェリー/.test(segment.category)) return "ferry";
  if (/巴士|バス/.test(segment.category)) return "bus";
  return "train";
}

function trainCategory(train: string, category: string): TrainCategory {
  const text = `${train} ${category}`;
  if (/新幹線|はやぶさ|やまびこ|こまち|Hayabusa/i.test(text)) return "shinkansen";
  if (/特急|N’EX|エクスプレス/.test(text)) return "limited_express";
  if (/快速/.test(text)) return "rapid";
  return "local";
}

function seatClass(seating: string): NonNullable<Segment["train"]>["seatClass"] {
  if (/無指定席|^普通車自由席/.test(seating)) return "non_reserved";
  if (/指定席/.test(seating)) return "reserved";
  if (/自由席/.test(seating)) return "non_reserved";
  return null;
}

function trainDetails(segment: RailSegment): Segment["train"] {
  const [left, right] = segment.category.includes(" · ") ? segment.category.split(" · ") : [null, segment.category];
  const number = segment.trainNumber ?? /\b(\d{1,5}[A-Z])\b/.exec(segment.train)?.[1] ?? null;
  const branded = /(はやぶさ|やまびこ|Hayabusa|成田エクスプレス N’EX|はこだてライナー)\s*(\d+)?/i.exec(segment.train);
  const line = segment.train.replace(/\(.*?\)|（.*?）/g, "").replace(number ?? "\u0000", "").trim();
  return {
    operator: /^JR/.test(segment.train) || /^JR/.test(left ?? "") ? "JR" : left?.includes("鐵道") ? left : null,
    line: left && !left.includes("鐵道") ? clip(left, 300) : line ? clip(line, 300) : null,
    name: branded ? branded[1] : null,
    number: branded?.[2] ?? number,
    category: trainCategory(segment.train, right ?? segment.category),
    carNumber: null,
    seat: null,
    seatClass: seatClass(segment.seating),
  };
}

function segmentOf(date: string, segment: RailSegment): Segment {
  const mode = segmentMode(segment);
  const departure = localTime(date, segment.departure);
  let arrival = localTime(date, segment.arrival);
  if (departure && arrival && arrival < departure) arrival = `${addDays(date, 1)}${arrival.slice(10)}`;
  // Fares shared across segments ("included in the through fare") live on the option, not the segment.
  const included = /^(已含|含於|含在|全程|共用)/.test(segment.price.trim());
  const price = included ? null : firstYen(segment.price);
  return {
    mode,
    fromPlaceId: STATION_PLACES[segment.from] ?? null,
    toPlaceId: STATION_PLACES[segment.to] ?? null,
    fromName: segment.from,
    toName: segment.to,
    departure,
    arrival,
    train: mode === "train" ? trainDetails(segment) : null,
    flight: null,
    price: price === null ? null : yen(price),
    sourceUrl: segment.sourceUrl || null,
  };
}

const sources = new Map<string, { title: string; url: string }>();
const addSources = (list: Source[] = []) => {
  for (const source of list) if (source.url && !sources.has(source.url)) sources.set(source.url, { title: clip(source.title, 300), url: source.url });
};
addSources(trip.sources);
addSources(fares.sources);

const transports: TripDocument["transports"] = rail.groups.map((group) => ({
  id: group.id,
  date: group.date,
  label: group.route,
  status: "planned",
  selectedOptionId: null,
  options: group.options.map((option) => {
    addSources(option.sources);
    const departure = localTime(group.date, option.departure);
    let arrival = localTime(group.date, option.arrival);
    if (departure && arrival && arrival < departure) arrival = `${addDays(group.date, 1)}${arrival.slice(10)}`;
    const fare = option.fareAmount ?? firstYen(option.fare);
    return {
      id: option.id,
      label: clip(option.label, 300),
      departure,
      arrival,
      duration: option.duration || null,
      fare: fare === null ? null : yen(fare),
      warning: option.warning ?? null,
      notes: [option.fare, ...option.notes].filter(Boolean).slice(0, 20),
      segments: option.segments.map((segment) => segmentOf(group.date, segment)),
    };
  }),
}));

/* Days ------------------------------------------------------------------------------------------- */

const SLOTS = ["morning", "afternoon", "evening", "night"] as const;

const days: TripDocument["days"] = trip.days.map((day) => {
  const date = dateOfDay(day.n);
  const route = routes[String(day.n)];
  return {
    id: `day-${day.n}`,
    date,
    title: day.title,
    short: day.short,
    blurb: day.blurb,
    highlight: day.highlight ?? false,
    route: route
      ? {
        kind: route.kind,
        placeIds: route.stops,
        path: route.points.length ? route.points.map(([lat, lng]) => ({ lat, lng })) : null,
        summary: route.summary,
      }
      : null,
    moments: day.moments.map((text, index) => ({ slot: SLOTS[Math.min(index, SLOTS.length - 1)], time: null, text, placeId: null })),
    tip: [day.transit, day.tip].filter(Boolean).join("\n\n") || null,
    stayId: stayOfDay.get(day.n) ?? null,
    transportIds: transports.filter((transport) => transport.date === date).map((transport) => transport.id),
  };
});

/* Expenses --------------------------------------------------------------------------------------- */

const PASS_ID = "jr-east-south-hokkaido-pass";
/** "10.14" → 2026-10-14. */
const fareDate = (text: string) => `2026-${text.split(".").map((part) => part.padStart(2, "0")).join("-")}`;

const expenses: TripDocument["expenses"] = [
  {
    id: PASS_ID,
    date: fares.pass.start,
    dayId: days.find((day) => day.date === fares.pass.start)?.id ?? null,
    category: "pass",
    title: `${fares.pass.name}（${fares.pass.start} – ${fares.pass.end}）`,
    amount: yen(fares.pass.price),
    paid: false,
    coveredByExpenseId: null,
    linkedId: null,
  },
  ...fares.rows.map((row) => {
    const date = fareDate(row.date);
    return {
      id: row.id,
      date,
      dayId: days.find((day) => day.date === date)?.id ?? null,
      category: "transport" as const,
      title: clip(`${row.route}${row.optional ? "（可选）" : ""}`, 300),
      amount: yen(row.fare),
      paid: false,
      coveredByExpenseId: row.covered ? PASS_ID : null,
      linkedId: transports.find((transport) => transport.date === date)?.id ?? null,
    };
  }),
];

/* Views ------------------------------------------------------------------------------------------ */

// The site's fare table recast as a custom view: the 6-day JR pass vs paying each leg by IC card
// (the IC fare where the site checked one, the paper fare where IC can't be used or wasn't checked).
const icFareOf = (row: FareRow): number | null => {
  const group = rail.groups.find((g) => g.date === fareDate(row.date));
  return group?.options.find((option) => option.icFare != null && firstYen(option.fare) === row.fare)?.icFare ?? null;
};
const mainRows = fares.rows.filter((row) => !row.optional);
const optionalRows = fares.rows.filter((row) => row.optional);
const payFare = (row: FareRow) => icFareOf(row) ?? row.fare;
const icTotal = mainRows.reduce((sum, row) => sum + payFare(row), 0);
const passTotal = fares.pass.price + mainRows.filter((row) => !row.covered).reduce((sum, row) => sum + payFare(row), 0);
const coveredTotal = mainRows.filter((row) => row.covered).reduce((sum, row) => sum + row.fare, 0);
const money = (amount: number) => `¥${amount.toLocaleString("en-US")}`;
const passDays = `${fares.pass.start.slice(5).replace("-", ".")}–${fares.pass.end.slice(5).replace("-", ".")}`;
const saving = passTotal - icTotal;

const views: TripDocument["views"] = [
  {
    id: "view-jr-pass-vs-ic",
    title: "JR Pass vs IC 卡逐程付款",
    dayId: null,
    spec: {
      root: "root",
      elements: {
        root: { type: "Stack", props: { gap: "large" }, children: ["intro", "stats", "verdict", "chart", "table", "optional", "how"] },
        intro: {
          type: "Text",
          props: { text: `${fares.pass.name} ${money(fares.pass.price)}，连续 6 天（${passDays}）。同一行程、成人 1 人：一边买周游券，有效期外的车程用 IC 卡；一边全程用 IC 卡（不能用 IC 的车程买纸票）逐程付款。`, tone: "muted" },
        },
        stats: { type: "Grid", props: { columns: 2 }, children: ["stat-pass", "stat-ic"] },
        "stat-pass": { type: "Stat", props: { label: "周游券方案", value: passTotal, format: "money", detail: `含周游券 ${money(fares.pass.price)}`, tone: saving < 0 ? "positive" : "default" } },
        "stat-ic": { type: "Stat", props: { label: "IC 卡逐程付款", value: icTotal, format: "money", detail: "不买周游券", tone: saving > 0 ? "positive" : "default" } },
        verdict: {
          type: "Callout",
          props: {
            title: saving > 0 ? `IC 卡逐程付款约省 ${money(saving)}` : saving < 0 ? `周游券方案约省 ${money(-saving)}` : "两种方案总额相同",
            text: `${passDays} 有效期内的车费合计 ${money(coveredTotal)}，${coveredTotal < fares.pass.price ? "低于" : "高于"}周游券本身 ${money(fares.pass.price)}。`,
            tone: "success",
          },
        },
        chart: {
          type: "BarChart",
          props: { title: "主行程交通合计", format: "money", items: [{ label: "周游券方案", value: passTotal, tone: "accent" }, { label: "IC 卡逐程付款", value: icTotal, tone: "positive" }] },
        },
        table: {
          type: "Table",
          props: {
            caption: "各段车费（日元）",
            columns: [
              { key: "date", label: "日期" },
              { key: "route", label: "路段" },
              { key: "ic", label: "IC 卡逐程", align: "trailing", format: "money", total: true },
              { key: "pass", label: "周游券方案", align: "trailing", format: "money", total: true },
            ],
            rows: [
              { cells: { date: "—", route: { value: "周游券本身", detail: `连续 6 天 · ${passDays}` }, ic: { value: "不购买", tone: "muted" }, pass: fares.pass.price }, style: "emphasis" },
              ...mainRows.map((row) => {
                const ic = icFareOf(row);
                const pay = { value: payFare(row), detail: ic != null ? "IC" : row.mode === "ferry" ? "渡轮另付" : "纸票" };
                return {
                  cells: {
                    date: row.date,
                    route: { value: row.route, detail: clip(row.note, 300) },
                    ic: pay,
                    pass: row.covered ? { value: "已包含", detail: "有效期内", tone: "positive" as const } : pay,
                  },
                  style: null,
                };
              }),
            ],
            totalLabel: "主行程合计",
          },
        },
        optional: { type: "Disclosure", props: { title: "可选：10.11 东京日游" }, children: ["optional-list"] },
        "optional-list": {
          type: "KeyValue",
          props: {
            items: optionalRows.map((row) => ({ label: row.route, value: icFareOf(row) ?? row.fare, format: "money" })),
          },
        },
        how: { type: "Disclosure", props: { title: "怎么算" }, children: ["how-list"] },
        "how-list": {
          type: "List",
          props: {
            items: [
              "IC 票价只有成田机场 ↔ 千叶、千叶 ↔ 东京已核对；其余车程按纸票价计。",
              "IC 卡不能跨 IC 区域使用，新干线也须另买车票：千叶 → 仙台、函馆 → 千叶等车程两种方案都按纸票计。",
              `周游券只在 ${passDays} 有效；渡轮及港口巴士两种方案都另付。`,
              "预算比较，不是订票报价或实时余票。",
            ],
          },
        },
      },
    },
  },
  {
    id: "view-pass-day-1",
    title: "周游券第 1 天",
    dayId: days.find((day) => day.date === fares.pass.start)?.id ?? null,
    spec: {
      root: "card",
      elements: {
        card: { type: "Card", props: { title: fares.pass.name, subtitle: `连续 6 天 · ${passDays}` }, children: ["facts", "note"] },
        facts: {
          type: "KeyValue",
          props: {
            items: [
              { label: "周游券", value: fares.pass.price, format: "money" },
              { label: "有效期内车费合计", value: coveredTotal, format: "money" },
              { label: "差额", value: coveredTotal - fares.pass.price, format: "money", tone: coveredTotal < fares.pass.price ? "negative" : "positive" },
            ],
          },
        },
        note: { type: "Callout", props: { text: "有效期内车费低于周游券价格时，用 IC 卡或纸票逐程付款更省。", tone: "tip" } },
      },
    },
  },
];

/* Document --------------------------------------------------------------------------------------- */

const document: TripDocument = {
  version: 1,
  title: "一路向北 · 2026 秋",
  subtitle: "成田・千叶至函馆 11 日",
  intro: trip.intro,
  startDate: START,
  endDate: dateOfDay(trip.days.length),
  timeZone: "Asia/Tokyo",
  currency: "JPY",
  places,
  days,
  transports,
  hotels,
  expenses,
  notes: [
    { id: "note-plan", title: "行程说明", text: trip.note },
    ...trip.notes.map((note, index) => ({ id: `note-${index + 1}`, title: note.title, text: note.text })),
    { id: "note-summary", title: "住宿分配与待定事项", text: trip.callout },
    ...(fares.optimized ? [{ id: "note-fare-optimized", title: fares.optimized.title, text: fares.optimized.text }] : []),
  ],
  sources: [...sources.values()].slice(0, 200),
  views,
  plans: [],
};

const parsed = tripDocumentSchema.safeParse(document);
if (!parsed.success) {
  console.error(parsed.error.issues.slice(0, 20));
  process.exit(1);
}
const out = new URL("../tests/fixtures/northbound-trip.json", import.meta.url).pathname;
writeFileSync(out, `${JSON.stringify(parsed.data, null, 2)}\n`);
console.log(`Wrote ${out}: ${days.length} days, ${places.length} places, ${transports.length} transports, ${hotels.length} hotels, ${expenses.length} expenses`);
