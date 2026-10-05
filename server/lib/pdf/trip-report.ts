import type { TripDocument } from "@/lib/contracts/trip";
import type { ViewElement, ViewSpec } from "@/lib/contracts/trip-view";
import type { PdfPageOptions } from "./browser-pdf";

/**
 * A trip as a printable report: a cover, the day-by-day itinerary, places as guidebook entries
 * (photos, info, prices, a directions link), stays, transport, the budget, planning views, notes
 * and sources. Self-contained HTML (inline CSS, no scripts) for Cloudflare's headless Chromium;
 * every value from the document is escaped and only https images are loaded.
 */

export const REPORT_LANGUAGES = ["en", "zh-Hans", "zh-Hant"] as const;
export type ReportLanguage = (typeof REPORT_LANGUAGES)[number];

const LABELS = {
  en: {
    day: (n: number) => `Day ${n}`, days: "Days", places: "Places", stays: "Stays", transport: "Transport", budget: "Budget",
    itinerary: "Itinerary", planning: "Planning", notes: "Notes", sources: "Sources", stay: "Stay", tip: "Tip", route: "Route",
    morning: "Morning", afternoon: "Afternoon", evening: "Evening", night: "Night", hours: "Hours", visit: "Visit",
    prices: "Prices", free: "Free", website: "Website", phone: "Phone", directions: "Directions", address: "Address",
    checkIn: "Check-in", checkOut: "Check-out", confirmation: "Confirmation", total: "Total", paid: "Paid", covered: "Covered",
    idea: "Idea", planned: "Planned", booked: "Booked", seat: "Seat", car: "Car", terminal: "Terminal", gate: "Gate",
    nights: (n: number) => (n === 1 ? "1 night" : `${n} nights`), generated: "Made with Chippy", page: "Page",
    item: "Item", category: "Category", amount: "Amount", date: "Date", fare: "Fare", status: "Status",
  },
  "zh-Hans": {
    day: (n: number) => `第 ${n} 天`, days: "天数", places: "地点", stays: "住宿", transport: "交通", budget: "预算",
    itinerary: "行程", planning: "规划", notes: "备注", sources: "来源", stay: "住宿", tip: "提示", route: "路线",
    morning: "上午", afternoon: "下午", evening: "傍晚", night: "夜间", hours: "营业时间", visit: "游览时长",
    prices: "价格", free: "免费", website: "网站", phone: "电话", directions: "导航", address: "地址",
    checkIn: "入住", checkOut: "退房", confirmation: "确认号", total: "合计", paid: "已付", covered: "已包含",
    idea: "构想", planned: "计划", booked: "已预订", seat: "座位", car: "车厢", terminal: "航站楼", gate: "登机口",
    nights: (n: number) => `${n} 晚`, generated: "由 Chippy 生成", page: "页",
    item: "项目", category: "类别", amount: "金额", date: "日期", fare: "票价", status: "状态",
  },
  "zh-Hant": {
    day: (n: number) => `第 ${n} 天`, days: "天數", places: "地點", stays: "住宿", transport: "交通", budget: "預算",
    itinerary: "行程", planning: "規劃", notes: "備註", sources: "來源", stay: "住宿", tip: "提示", route: "路線",
    morning: "上午", afternoon: "下午", evening: "傍晚", night: "夜間", hours: "營業時間", visit: "遊覽時長",
    prices: "價格", free: "免費", website: "網站", phone: "電話", directions: "導航", address: "地址",
    checkIn: "入住", checkOut: "退房", confirmation: "確認號碼", total: "合計", paid: "已付", covered: "已包含",
    idea: "構想", planned: "計畫", booked: "已預訂", seat: "座位", car: "車廂", terminal: "航廈", gate: "登機門",
    nights: (n: number) => `${n} 晚`, generated: "由 Chippy 製作", page: "頁",
    item: "項目", category: "類別", amount: "金額", date: "日期", fare: "票價", status: "狀態",
  },
} satisfies Record<ReportLanguage, unknown>;

type Labels = (typeof LABELS)["en"];

const CATEGORY_LABELS: Record<ReportLanguage, Record<string, string>> = {
  en: { transport: "Transport", lodging: "Lodging", food: "Food", activity: "Activities", shopping: "Shopping", pass: "Passes", other: "Other" },
  "zh-Hans": { transport: "交通", lodging: "住宿", food: "餐饮", activity: "活动", shopping: "购物", pass: "通票", other: "其他" },
  "zh-Hant": { transport: "交通", lodging: "住宿", food: "餐飲", activity: "活動", shopping: "購物", pass: "通票", other: "其他" },
};

const MODE_ICONS: Record<string, string> = { train: "🚆", flight: "✈️", ferry: "⛴️", bus: "🚌", car: "🚗", walk: "🚶", other: "•" };

/** The report language for a `lang` query or `Accept-Language` header: Chinese scripts, else English. */
export function reportLanguage(requested: string | null | undefined): ReportLanguage {
  for (const tag of (requested ?? "").split(",").map((part) => part.split(";")[0].trim().toLowerCase())) {
    if (!tag) continue;
    if (tag.startsWith("zh")) return /hant|-tw|-hk|-mo/.test(tag) ? "zh-Hant" : "zh-Hans";
    if (tag.startsWith("en")) return "en";
  }
  return "en";
}

export function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

/** Text with line breaks kept. */
const prose = (value: string | null | undefined) => escapeHtml(value).replaceAll("\n", "<br>");

/** Only http(s) links and https images make it into the page. */
function safeUrl(value: string | null | undefined, images = false): string | null {
  if (!value) return null;
  try {
    const parsed = new URL(value);
    if (parsed.protocol === "https:" || (!images && parsed.protocol === "http:")) return parsed.toString();
  } catch {
    // Not a URL.
  }
  return null;
}

const localeOf = (language: ReportLanguage) => (language === "en" ? "en-GB" : language === "zh-Hans" ? "zh-CN" : "zh-TW");

function formatDate(date: string, language: ReportLanguage, style: "long" | "short" = "long"): string {
  const parsed = new Date(`${date}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime())) return date;
  return new Intl.DateTimeFormat(localeOf(language), style === "long"
    ? { weekday: "short", day: "numeric", month: "short", year: "numeric", timeZone: "UTC" }
    : { day: "numeric", month: "short", timeZone: "UTC" }).format(parsed);
}

function formatMoney(amount: number, currency: string, language: ReportLanguage): string {
  try {
    return new Intl.NumberFormat(localeOf(language), { style: "currency", currency, maximumFractionDigits: 2 }).format(amount);
  } catch {
    return `${amount} ${currency}`;
  }
}

const money = (value: { amount: number; currency: string } | null | undefined, language: ReportLanguage) =>
  value ? formatMoney(value.amount, value.currency, language) : "";

/** `2026-11-06T15:16` → `15:16`. */
const clock = (value: string | null | undefined) => value?.slice(11, 16) ?? "";

function daysBetween(from: string, to: string): number {
  return Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000);
}

/** Opens directions to the coordinate in Google Maps (works on every device the PDF is read on). */
export function directionsUrl(lat: number, lng: number): string {
  return `https://www.google.com/maps/dir/?api=1&destination=${lat.toFixed(6)},${lng.toFixed(6)}`;
}

/* ------------------------------------------------------------------------------------------------
 * Custom views
 * ---------------------------------------------------------------------------------------------- */

interface ViewContext {
  spec: ViewSpec;
  currency: string;
  language: ReportLanguage;
  doc: TripDocument;
  labels: Labels;
}

type ViewValue = string | number | null | undefined;

function viewValue(value: ViewValue, format: string | null | undefined, currency: string | null | undefined, ctx: ViewContext): string {
  if (value === null || value === undefined) return "—";
  if (typeof value === "string") return escapeHtml(value);
  if (format === "money") return escapeHtml(formatMoney(value, currency ?? ctx.currency, ctx.language));
  if (format === "percent") return escapeHtml(`${Number((value).toFixed(1))}%`);
  return escapeHtml(new Intl.NumberFormat(localeOf(ctx.language)).format(value));
}

const toneClass = (tone: string | null | undefined) => (tone && tone !== "default" ? ` tone-${tone}` : "");

function renderElement(id: string, ctx: ViewContext, depth: number, seen: Set<string>): string {
  const element = ctx.spec.elements[id] as ViewElement | undefined;
  if (!element || depth > 24 || seen.has(id)) return "";
  seen.add(id);
  const children = () => ("children" in element ? element.children ?? [] : []).map((child) => renderElement(child, ctx, depth + 1, seen)).join("");
  switch (element.type) {
    case "Stack":
      return `<div class="v-stack${element.props.direction === "horizontal" ? " v-row" : ""} gap-${element.props.gap ?? "medium"}">${children()}</div>`;
    case "Grid":
      return `<div class="v-grid" style="grid-template-columns: repeat(${element.props.columns ?? 2}, minmax(0, 1fr))">${children()}</div>`;
    case "Card":
      return `<div class="v-card${toneClass(element.props.tone)}">${element.props.title ? `<div class="v-card-title">${escapeHtml(element.props.title)}</div>` : ""}${element.props.subtitle ? `<div class="muted small">${escapeHtml(element.props.subtitle)}</div>` : ""}${children()}</div>`;
    case "Disclosure":
      // Printed open: paper can't expand.
      return `<div class="v-disclosure"><div class="v-card-title">${escapeHtml(element.props.title)}</div>${children()}</div>`;
    case "Heading": {
      const level = (element.props.level ?? 2) + 2;
      return `<h${level} class="v-heading">${escapeHtml(element.props.text)}</h${level}>`;
    }
    case "Text":
      return `<p class="v-text size-${element.props.size ?? "body"} weight-${element.props.weight ?? "regular"}${toneClass(element.props.tone)}">${prose(element.props.text)}</p>`;
    case "Badge":
      return `<span class="badge${toneClass(element.props.tone)}">${escapeHtml(element.props.text)}</span>`;
    case "Stat":
      return `<div class="v-stat${toneClass(element.props.tone)}"><div class="muted small">${escapeHtml(element.props.label)}</div><div class="v-stat-value">${viewValue(element.props.value, element.props.format, element.props.currency, ctx)}</div>${element.props.detail ? `<div class="muted small">${escapeHtml(element.props.detail)}</div>` : ""}</div>`;
    case "Callout":
      return `<div class="callout callout-${element.props.tone ?? "info"}">${element.props.title ? `<strong>${escapeHtml(element.props.title)}</strong> ` : ""}${prose(element.props.text)}</div>`;
    case "KeyValue":
      return `<dl class="kv">${element.props.items.map((item) => `<dt>${escapeHtml(item.label)}</dt><dd class="${toneClass(item.tone).trim()}">${viewValue(item.value, item.format, item.currency, ctx)}</dd>`).join("")}</dl>`;
    case "List": {
      const tag = element.props.ordered ? "ol" : "ul";
      return `<${tag} class="v-list">${element.props.items.map((item) => `<li>${prose(item)}</li>`).join("")}</${tag}>`;
    }
    case "Table": {
      const { columns, rows } = element.props;
      const cell = (raw: unknown, column: (typeof columns)[number]) => {
        const detailed = raw !== null && typeof raw === "object" ? (raw as { value: ViewValue; detail?: string | null; tone?: string | null }) : null;
        const value = detailed ? detailed.value : (raw as ViewValue);
        return `<td class="align-${column.align ?? "leading"}${toneClass(detailed?.tone)}">${viewValue(value, column.format, column.currency, ctx)}${detailed?.detail ? `<div class="muted small">${escapeHtml(detailed.detail)}</div>` : ""}</td>`;
      };
      const totals = columns.some((column) => column.total)
        ? `<tr class="row-total">${columns.map((column, index) => {
          if (!column.total) return `<td>${index === 0 ? escapeHtml(element.props.totalLabel ?? ctx.labels.total) : ""}</td>`;
          const sum = rows.filter((row) => row.style !== "total").reduce((acc, row) => {
            const raw = row.cells[column.key];
            const value = raw !== null && typeof raw === "object" ? raw.value : raw;
            return acc + (typeof value === "number" ? value : 0);
          }, 0);
          return `<td class="align-${column.align ?? "trailing"}">${viewValue(sum, column.format, column.currency, ctx)}</td>`;
        }).join("")}</tr>`
        : "";
      return `<table class="table">${element.props.caption ? `<caption>${escapeHtml(element.props.caption)}</caption>` : ""}<thead><tr>${columns.map((column) => `<th class="align-${column.align ?? "leading"}">${escapeHtml(column.label)}</th>`).join("")}</tr></thead><tbody>${rows.map((row) => `<tr class="row-${row.style ?? "default"}">${columns.map((column) => cell(row.cells[column.key], column)).join("")}</tr>`).join("")}${totals}</tbody></table>`;
    }
    case "BarChart": {
      const max = Math.max(...element.props.items.map((item) => Math.abs(item.value)), 1);
      return `<div class="bars">${element.props.title ? `<div class="v-card-title">${escapeHtml(element.props.title)}</div>` : ""}${element.props.items.map((item) => `<div class="bar-row"><div class="bar-label">${escapeHtml(item.label)}</div><div class="bar-track"><div class="bar${toneClass(item.tone)}" style="width:${((Math.abs(item.value) / max) * 100).toFixed(1)}%"></div></div><div class="bar-value">${viewValue(item.value, element.props.format, element.props.currency, ctx)}</div></div>`).join("")}</div>`;
    }
    case "Divider":
      return `<hr>`;
    case "Link": {
      const href = safeUrl(element.props.url);
      return href ? `<a class="v-link" href="${escapeHtml(href)}">${escapeHtml(element.props.title)}</a>` : "";
    }
    case "Image": {
      const src = safeUrl(element.props.url, true);
      return src ? figure(src, element.props.caption, element.props.credit, `aspect-${element.props.aspect ?? "wide"}`) : "";
    }
    case "Gallery":
      return `<div class="gallery">${element.props.images.map((image) => {
        const src = safeUrl(image.url, true);
        return src ? figure(src, image.caption, image.credit, "aspect-square") : "";
      }).join("")}</div>`;
    case "Place": {
      const place = ctx.doc.places.find((candidate) => candidate.id === element.props.placeId);
      return place ? placeEntry(place, ctx.language, ctx.labels, true) : "";
    }
    default:
      return "";
  }
}

export function renderViewHtml(spec: ViewSpec, doc: TripDocument, language: ReportLanguage = "en"): string {
  return renderElement(spec.root, { spec, currency: doc.currency, language, doc, labels: LABELS[language] }, 0, new Set());
}

/* ------------------------------------------------------------------------------------------------
 * Sections
 * ---------------------------------------------------------------------------------------------- */

function figure(src: string, caption: string | null | undefined, credit: string | null | undefined, className: string): string {
  const text = [caption ? escapeHtml(caption) : "", credit ? `<span class="credit">${escapeHtml(credit)}</span>` : ""].filter(Boolean).join(" ");
  return `<figure class="photo ${className}"><img src="${escapeHtml(src)}" alt="${escapeHtml(caption ?? "")}">${text ? `<figcaption>${text}</figcaption>` : ""}</figure>`;
}

type Place = TripDocument["places"][number];

function placeEntry(place: Place, language: ReportLanguage, t: Labels, compact = false): string {
  const photos = place.photos.map((photo) => ({ ...photo, src: safeUrl(photo.url, true) })).filter((photo) => photo.src);
  const [lead, ...more] = photos;
  const facts: [string, string][] = [];
  if (place.address) facts.push([t.address, escapeHtml(place.address)]);
  if (place.hours) facts.push([t.hours, escapeHtml(place.hours)]);
  if (place.visitDuration) facts.push([t.visit, escapeHtml(place.visitDuration)]);
  const website = safeUrl(place.website);
  if (website) facts.push([t.website, `<a href="${escapeHtml(website)}">${escapeHtml(new URL(website).hostname.replace(/^www\./, ""))}</a>`]);
  if (place.phone) facts.push([t.phone, `<a href="tel:${escapeHtml(place.phone.replace(/[^+\d]/g, ""))}">${escapeHtml(place.phone)}</a>`]);
  const { lat, lng } = place.coordinate;
  facts.push([t.directions, `<a href="${escapeHtml(directionsUrl(lat, lng))}">📍 ${lat.toFixed(5)}, ${lng.toFixed(5)}</a>`]);

  const pricing = place.pricing.length
    ? `<table class="table prices"><thead><tr><th>${escapeHtml(t.prices)}</th><th class="align-trailing"></th></tr></thead><tbody>${place.pricing.map((item) => `<tr><td>${escapeHtml(item.label)}${item.note ? `<div class="muted small">${escapeHtml(item.note)}</div>` : ""}</td><td class="align-trailing">${escapeHtml(item.price ? money(item.price, language) : t.free)}</td></tr>`).join("")}</tbody></table>`
    : "";
  return `<article class="place${compact ? " place-compact" : ""}" id="place-${escapeHtml(place.id)}">
    ${lead ? figure(lead.src!, lead.caption, lead.credit, "aspect-wide") : ""}
    <div class="place-head"><h3>${escapeHtml(place.name)}</h3></div>
    ${place.description ? `<p>${prose(place.description)}</p>` : ""}
    <dl class="kv">${facts.map(([label, value]) => `<dt>${escapeHtml(label)}</dt><dd>${value}</dd>`).join("")}</dl>
    ${pricing}
    ${place.note ? `<p class="muted">${prose(place.note)}</p>` : ""}
    ${!compact && more.length ? `<div class="gallery">${more.map((photo) => figure(photo.src!, photo.caption, photo.credit, "aspect-square")).join("")}</div>` : ""}
  </article>`;
}

function transportBlock(transport: TripDocument["transports"][number], language: ReportLanguage, t: Labels): string {
  const option = transport.options.find((candidate) => candidate.id === transport.selectedOptionId) ?? transport.options[0];
  const times = option.departure || option.arrival ? `${clock(option.departure)} → ${clock(option.arrival)}` : "";
  const segments = option.segments.map((segment) => {
    const details: string[] = [];
    if (segment.train) {
      details.push([segment.train.operator, segment.train.name, segment.train.number].filter(Boolean).join(" "));
      if (segment.train.carNumber) details.push(`${t.car} ${segment.train.carNumber}`);
      if (segment.train.seat) details.push(`${t.seat} ${segment.train.seat}`);
    }
    if (segment.flight) {
      details.push([segment.flight.airline, segment.flight.flightNumber].filter(Boolean).join(" "));
      if (segment.flight.terminal) details.push(`${t.terminal} ${segment.flight.terminal}`);
      if (segment.flight.gate) details.push(`${t.gate} ${segment.flight.gate}`);
      if (segment.flight.seat) details.push(`${t.seat} ${segment.flight.seat}`);
    }
    const when = segment.departure || segment.arrival ? `<span class="time">${clock(segment.departure)}–${clock(segment.arrival)}</span> ` : "";
    return `<li>${MODE_ICONS[segment.mode] ?? "•"} ${when}${escapeHtml(segment.fromName)} → ${escapeHtml(segment.toName)}${details.filter(Boolean).length ? ` <span class="muted">· ${escapeHtml(details.filter(Boolean).join(" · "))}</span>` : ""}</li>`;
  }).join("");
  return `<div class="transport">
    <div class="row-between"><strong>${escapeHtml(transport.label)}</strong><span class="badge status-${transport.status}">${escapeHtml(t[transport.status])}</span></div>
    <div class="muted small">${escapeHtml([option.label, times, option.duration, money(option.fare, language)].filter(Boolean).join(" · "))}</div>
    ${segments ? `<ul class="segments">${segments}</ul>` : ""}
    ${option.warning ? `<div class="callout callout-warning">${prose(option.warning)}</div>` : ""}
  </div>`;
}

function totalsByCurrency(expenses: TripDocument["expenses"]): Map<string, number> {
  const totals = new Map<string, number>();
  for (const expense of expenses) {
    if (expense.coveredByExpenseId) continue;
    totals.set(expense.amount.currency, (totals.get(expense.amount.currency) ?? 0) + expense.amount.amount);
  }
  return totals;
}

const STYLES = `
  * { box-sizing: border-box; }
  html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  body { margin: 0; font-family: "Helvetica Neue", Helvetica, Arial, "Noto Sans CJK SC", "Noto Sans CJK TC", "Noto Sans CJK JP", "WenQuanYi Zen Hei", "Noto Color Emoji", sans-serif; font-size: 10.5pt; line-height: 1.5; color: #1d1d1f; }
  h1 { font-size: 30pt; line-height: 1.15; margin: 0 0 6pt; letter-spacing: -0.02em; }
  h2 { font-size: 17pt; margin: 0 0 12pt; padding-bottom: 6pt; border-bottom: 2px solid #1d1d1f; }
  h3 { font-size: 13pt; margin: 0 0 4pt; }
  h4, h5 { margin: 8pt 0 4pt; }
  p { margin: 0 0 6pt; }
  a { color: #0a66c2; text-decoration: none; }
  hr { border: 0; border-top: 1px solid #e5e5ea; margin: 10pt 0; }
  .muted { color: #6e6e73; } .small { font-size: 8.5pt; }
  .section { break-before: page; }
  .cover { padding-top: 40mm; }
  .cover .subtitle { font-size: 14pt; color: #6e6e73; margin-bottom: 10pt; }
  .cover .dates { font-size: 12pt; font-weight: 600; margin-bottom: 18pt; }
  .cover .intro { font-size: 11.5pt; max-width: 150mm; }
  .stats { display: flex; gap: 10pt; margin-top: 24pt; }
  .stat { flex: 1; }
  .stat-value { font-size: 18pt; font-weight: 700; }
  .day { padding-bottom: 12pt; margin-bottom: 12pt; border-bottom: 1px solid #e5e5ea; }
  .day.highlight .day-kicker { color: #b25e00; }
  .day-kicker { font-size: 8.5pt; font-weight: 700; text-transform: uppercase; letter-spacing: 0.06em; color: #6e6e73; }
  .moments { list-style: none; padding: 0; margin: 8pt 0; }
  .moments li { display: flex; gap: 8pt; padding: 3pt 0; border-top: 1px dashed #e5e5ea; }
  .moments li:first-child { border-top: 0; }
  .slot { flex: 0 0 22mm; color: #6e6e73; font-size: 9pt; }
  .time { font-variant-numeric: tabular-nums; font-weight: 600; }
  .row-between { display: flex; justify-content: space-between; align-items: baseline; gap: 8pt; }
  .transport { margin: 8pt 0; break-inside: avoid; }
  .segments { margin: 4pt 0 0; padding-left: 0; list-style: none; font-size: 9.5pt; }
  .badge { display: inline-block; font-size: 7.5pt; font-weight: 700; color: #1d1d1f; white-space: nowrap; }
  .status-booked { color: #0b6b2c; } .status-idea { color: #6e6e73; }
  .callout { margin: 6pt 0; font-size: 9.5pt; }
  .callout-tip { color: #b25e00; } .callout-warning { color: #c9302c; } .callout-success { color: #1a8a3f; }
  .kv { display: grid; grid-template-columns: max-content 1fr; gap: 2pt 10pt; margin: 6pt 0; font-size: 9.5pt; }
  .kv dt { color: #6e6e73; } .kv dd { margin: 0; }
  .table { width: 100%; border-collapse: collapse; margin: 6pt 0; font-size: 9.5pt; break-inside: auto; }
  .table caption { text-align: left; font-weight: 600; margin-bottom: 4pt; }
  .table th { text-align: left; font-size: 8.5pt; color: #6e6e73; border-bottom: 1px solid #d2d2d7; padding: 4pt 6pt; }
  .table td { border-bottom: 1px solid #f0f0f2; padding: 4pt 6pt; vertical-align: top; }
  .table tr { break-inside: avoid; }
  .row-total td, .row-emphasis td { font-weight: 700; } .row-muted td { color: #6e6e73; }
  .align-trailing { text-align: right !important; } .align-center { text-align: center !important; }
  .place { margin-bottom: 16pt; padding-bottom: 12pt; border-bottom: 1px solid #e5e5ea; }
  .place-compact { margin-bottom: 10pt; padding-bottom: 8pt; }
  .photo { margin: 0 0 8pt; break-inside: avoid; }
  .photo img { display: block; width: 100%; object-fit: cover; }
  .aspect-wide img { aspect-ratio: 16 / 9; max-height: 75mm; } .aspect-square img { aspect-ratio: 1; max-height: 75mm; } .aspect-portrait img { aspect-ratio: 3 / 4; max-height: 100mm; }
  .gallery .photo img { max-height: 55mm; }
  .photo figcaption { font-size: 8pt; color: #6e6e73; margin-top: 2pt; }
  .credit { opacity: 0.8; }
  /* Long sections flow across pages; small blocks stay whole and headings stay with what follows. */
  h2, h3, .day-kicker, .view-title, .v-card-title, .place-head { break-after: avoid; }
  .moments li, .kv, .stat, .v-stat, .bar-row { break-inside: avoid; }
  .gallery { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 6pt; margin: 6pt 0; }
  .gallery .photo { margin: 0; }
  .view { margin: 10pt 0 12pt; }
  .view-title { font-weight: 700; font-size: 12pt; margin-bottom: 8pt; }
  .v-stack { display: flex; flex-direction: column; } .v-row { flex-direction: row; align-items: flex-start; }
  .v-row > * { flex: 1; }
  .gap-none { gap: 0; } .gap-small { gap: 4pt; } .gap-medium { gap: 8pt; } .gap-large { gap: 14pt; }
  .v-grid { display: grid; gap: 8pt; }
  .v-card, .v-disclosure { margin: 6pt 0; }
  .v-card-title { font-weight: 700; margin-bottom: 4pt; }
  .v-stat-value { font-size: 15pt; font-weight: 700; }
  .size-small { font-size: 8.5pt; } .size-large { font-size: 12.5pt; }
  .weight-semibold { font-weight: 600; } .weight-bold { font-weight: 700; }
  .tone-muted { color: #6e6e73; } .tone-accent { color: #0a66c2; } .tone-positive { color: #1a8a3f; } .tone-negative { color: #c9302c; } .tone-warning { color: #b25e00; }
  .v-list { margin: 4pt 0; padding-left: 16pt; }
  .bars { margin: 6pt 0; } .bar-row { display: flex; align-items: center; gap: 8pt; font-size: 9pt; margin: 3pt 0; }
  .bar-label { flex: 0 0 35%; } .bar-value { flex: 0 0 22%; text-align: right; font-variant-numeric: tabular-nums; }
  .bar-track { flex: 1; height: 8pt; background: #f2f2f7; overflow: hidden; }
  .bar { height: 100%; background: #0a66c2; } .bar.tone-positive { background: #1a8a3f; } .bar.tone-negative { background: #c9302c; } .bar.tone-warning { background: #ff9f0a; } .bar.tone-muted { background: #aeaeb2; }
  .sources li { margin-bottom: 3pt; word-break: break-all; }
`;

/** Chromium's header and footer templates: inline styles only, and no access to the page's fonts. */
function pageTemplates(doc: TripDocument, language: ReportLanguage, t: Labels): PdfPageOptions {
  const font = `font-family: Helvetica, Arial, 'Noto Sans CJK SC', 'Noto Sans CJK TC', sans-serif; font-size: 8px; color: #8e8e93;`;
  const range = `${formatDate(doc.startDate, language, "short")} – ${formatDate(doc.endDate, language, "short")}`;
  const page = language === "en"
    ? `${t.page} <span class="pageNumber"></span> / <span class="totalPages"></span>`
    : `<span class="pageNumber"></span> / <span class="totalPages"></span> ${t.page}`;
  return {
    headerTemplate: `<div style="${font} width: 100%; margin: 0 16mm; padding-bottom: 4px; border-bottom: 0.5px solid #d2d2d7; display: flex; justify-content: space-between;"><span>${escapeHtml(doc.title)}</span><span>${escapeHtml(range)}</span></div>`,
    footerTemplate: `<div style="${font} width: 100%; margin: 0 16mm; display: flex; justify-content: space-between;"><span>${escapeHtml(t.generated)}</span><span>${page}</span></div>`,
    margin: { top: "22mm", bottom: "18mm", left: "16mm", right: "16mm" },
  };
}

/** The report's HTML and the page header/footer to print it with. */
export function renderTripReport(doc: TripDocument, language: ReportLanguage = "en"): { html: string; page: PdfPageOptions } {
  const t = LABELS[language];
  const places = new Map(doc.places.map((place) => [place.id, place]));
  const hotels = new Map(doc.hotels.map((hotel) => [hotel.id, hotel]));
  const transports = new Map(doc.transports.map((transport) => [transport.id, transport]));
  const days = [...doc.days].sort((a, b) => a.date.localeCompare(b.date));
  const tripDays = Math.max(1, daysBetween(doc.startDate, doc.endDate) + 1);
  const totals = totalsByCurrency(doc.expenses);
  const view = (v: TripDocument["views"][number]) => `<div class="view"><div class="view-title">${escapeHtml(v.title)}</div>${renderViewHtml(v.spec, doc, language)}</div>`;

  const cover = `<section class="cover">
    <h1>${escapeHtml(doc.title)}</h1>
    ${doc.subtitle ? `<div class="subtitle">${escapeHtml(doc.subtitle)}</div>` : ""}
    <div class="dates">${escapeHtml(formatDate(doc.startDate, language))} – ${escapeHtml(formatDate(doc.endDate, language))}</div>
    ${doc.intro ? `<div class="intro">${prose(doc.intro)}</div>` : ""}
    <div class="stats">
      <div class="stat"><div class="muted small">${escapeHtml(t.days)}</div><div class="stat-value">${tripDays}</div></div>
      <div class="stat"><div class="muted small">${escapeHtml(t.places)}</div><div class="stat-value">${doc.places.length}</div></div>
      <div class="stat"><div class="muted small">${escapeHtml(t.stays)}</div><div class="stat-value">${doc.hotels.length}</div></div>
      ${totals.size ? `<div class="stat"><div class="muted small">${escapeHtml(t.budget)}</div><div class="stat-value">${[...totals].map(([currency, amount]) => escapeHtml(formatMoney(amount, currency, language))).join("<br>")}</div></div>` : ""}
    </div>
  </section>`;

  const itinerary = days.length ? `<section class="section"><h2>${escapeHtml(t.itinerary)}</h2>${days.map((day, index) => {
    const route = day.route?.placeIds.map((id) => places.get(id)?.name).filter(Boolean).join(" → ");
    const stay = day.stayId ? hotels.get(day.stayId) : undefined;
    const moments = day.moments.map((moment) => {
      const place = moment.placeId ? places.get(moment.placeId) : undefined;
      const where = place ? ` <a class="muted" href="${escapeHtml(directionsUrl(place.coordinate.lat, place.coordinate.lng))}">· ${escapeHtml(place.name)}</a>` : "";
      return `<li><span class="slot">${moment.time ? `<span class="time">${escapeHtml(moment.time)}</span>` : escapeHtml(t[moment.slot])}</span><span>${prose(moment.text)}${where}</span></li>`;
    }).join("");
    const dayViews = doc.views.filter((v) => v.dayId === day.id).map(view).join("");
    return `<article class="day${day.highlight ? " highlight" : ""}" id="${escapeHtml(day.id)}">
      <div class="day-kicker">${escapeHtml(t.day(index + 1))} · ${escapeHtml(formatDate(day.date, language))}</div>
      <h3>${escapeHtml(day.title)}${day.short ? ` <span class="muted small">${escapeHtml(day.short)}</span>` : ""}</h3>
      ${day.blurb ? `<p>${prose(day.blurb)}</p>` : ""}
      ${route ? `<div class="small"><strong>${escapeHtml(t.route)}</strong> ${escapeHtml(route)}${day.route?.summary ? ` <span class="muted">· ${escapeHtml(day.route.summary)}</span>` : ""}</div>` : ""}
      ${moments ? `<ul class="moments">${moments}</ul>` : ""}
      ${day.transportIds.map((id) => transports.get(id)).filter((x) => x !== undefined).map((transport) => transportBlock(transport, language, t)).join("")}
      ${stay ? `<div class="small"><strong>${escapeHtml(t.stay)}</strong> ${escapeHtml(stay.name)}${stay.address ? ` <span class="muted">· ${escapeHtml(stay.address)}</span>` : ""}</div>` : ""}
      ${day.tip ? `<div class="callout callout-tip"><strong>${escapeHtml(t.tip)}</strong> ${prose(day.tip)}</div>` : ""}
      ${dayViews}
    </article>`;
  }).join("")}</section>` : "";

  const placesSection = doc.places.length
    ? `<section class="section"><h2>${escapeHtml(t.places)}</h2>${doc.places.map((place) => placeEntry(place, language, t)).join("")}</section>`
    : "";

  const staysSection = doc.hotels.length ? `<section class="section"><h2>${escapeHtml(t.stays)}</h2><table class="table"><thead><tr><th>${escapeHtml(t.stays)}</th><th>${escapeHtml(t.checkIn)}</th><th>${escapeHtml(t.checkOut)}</th><th>${escapeHtml(t.status)}</th><th class="align-trailing">${escapeHtml(t.amount)}</th></tr></thead><tbody>${[...doc.hotels].sort((a, b) => a.checkIn.localeCompare(b.checkIn)).map((hotel) => {
    const link = safeUrl(hotel.url);
    const name = link ? `<a href="${escapeHtml(link)}">${escapeHtml(hotel.name)}</a>` : escapeHtml(hotel.name);
    const detail = [hotel.address, hotel.confirmation ? `${t.confirmation} ${hotel.confirmation}` : null, t.nights(Math.max(0, daysBetween(hotel.checkIn, hotel.checkOut)))].filter(Boolean).join(" · ");
    return `<tr><td>${name}<div class="muted small">${escapeHtml(detail)}</div></td><td>${escapeHtml(formatDate(hotel.checkIn, language, "short"))}${hotel.checkInTime ? ` ${escapeHtml(hotel.checkInTime)}` : ""}</td><td>${escapeHtml(formatDate(hotel.checkOut, language, "short"))}</td><td><span class="badge status-${hotel.status}">${escapeHtml(t[hotel.status])}</span></td><td class="align-trailing">${escapeHtml(money(hotel.price, language))}</td></tr>`;
  }).join("")}</tbody></table></section>` : "";

  const transportSection = doc.transports.length
    ? `<section class="section"><h2>${escapeHtml(t.transport)}</h2>${[...doc.transports].sort((a, b) => a.date.localeCompare(b.date)).map((transport) => `<div class="muted small">${escapeHtml(formatDate(transport.date, language))}</div>${transportBlock(transport, language, t)}`).join("")}</section>`
    : "";

  const categories = CATEGORY_LABELS[language];
  const budgetSection = doc.expenses.length ? `<section class="section"><h2>${escapeHtml(t.budget)}</h2><table class="table"><thead><tr><th>${escapeHtml(t.item)}</th><th>${escapeHtml(t.category)}</th><th>${escapeHtml(t.date)}</th><th class="align-trailing">${escapeHtml(t.amount)}</th></tr></thead><tbody>${[...doc.expenses].sort((a, b) => (a.date ?? "9999").localeCompare(b.date ?? "9999")).map((expense) => {
    const flags = [expense.paid ? t.paid : null, expense.coveredByExpenseId ? t.covered : null].filter(Boolean).join(" · ");
    return `<tr class="${expense.coveredByExpenseId ? "row-muted" : ""}"><td>${escapeHtml(expense.title)}${flags ? `<div class="muted small">${escapeHtml(flags)}</div>` : ""}</td><td>${escapeHtml(categories[expense.category] ?? expense.category)}</td><td>${expense.date ? escapeHtml(formatDate(expense.date, language, "short")) : ""}</td><td class="align-trailing">${escapeHtml(money(expense.amount, language))}</td></tr>`;
  }).join("")}${[...totals].map(([currency, amount]) => `<tr class="row-total"><td colspan="3">${escapeHtml(t.total)} (${escapeHtml(currency)})</td><td class="align-trailing">${escapeHtml(formatMoney(amount, currency, language))}</td></tr>`).join("")}</tbody></table></section>` : "";

  const tripViews = doc.views.filter((v) => !v.dayId || !doc.days.some((day) => day.id === v.dayId));
  const planningSection = tripViews.length ? `<section class="section"><h2>${escapeHtml(t.planning)}</h2>${tripViews.map(view).join("")}</section>` : "";

  const notesSection = doc.notes.length
    ? `<section class="section"><h2>${escapeHtml(t.notes)}</h2>${doc.notes.map((note) => `<div class="view"><div class="view-title">${escapeHtml(note.title)}</div><p>${prose(note.text)}</p></div>`).join("")}</section>`
    : "";

  const sourcesSection = doc.sources.length
    ? `<section><h2 style="margin-top:18pt">${escapeHtml(t.sources)}</h2><ol class="sources small">${doc.sources.map((source) => {
      const href = safeUrl(source.url);
      return `<li>${escapeHtml(source.title)}${href ? ` — <a href="${escapeHtml(href)}">${escapeHtml(href)}</a>` : ""}</li>`;
    }).join("")}</ol></section>`
    : "";

  const html = `<!doctype html><html lang="${language}"><head><meta charset="utf-8"><title>${escapeHtml(doc.title)}</title><style>${STYLES}</style></head><body>${cover}${itinerary}${planningSection}${placesSection}${staysSection}${transportSection}${budgetSection}${notesSection}${sourcesSection}</body></html>`;
  return { html, page: pageTemplates(doc, language, t) };
}
