import { Worker } from "node:worker_threads";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import satori, { type Font } from "satori";
import { Resvg } from "@resvg/resvg-js";
import { FRAME_RUNTIME } from "./frame-runtime";
import { PODCAST_VIDEO_PHRASES, PODCAST_VIDEO_SCAFFOLD, bundleIssues, bundlePodcastProject } from "./scaffold";

/**
 * Server-side single-frame preview of an agent composition, so the agent can look at what it wrote and
 * so submissions with overlapping or clipped text are caught before the app renders them.
 *
 * The untrusted source runs in QuickJS (frame-worker.mjs) against a small React/Remotion stand-in and
 * returns an element tree. Satori lays out the HTML; inline SVGs are swapped for marker boxes during
 * layout and spliced back at their exact box and stacking position, because Satori can't draw SVG text.
 * Resvg paints the PNG. Layout follows WebKit closely but not exactly (no CSS files, flex for blocks).
 */

type Tree = string | { t: string; p: Record<string, unknown>; c: Tree[] };
type Matrix = [number, number, number, number, number, number];
interface Box { x: number; y: number; width: number; height: number }
export interface FrameText extends Box { text: string; fontSize: number }
export interface PreviewFrame { seconds: number; speaking: boolean }
export interface FrameReport {
  seconds: number;
  /** Problems the device render will show too: overlapping or clipped text, runtime errors. */
  issues: string[];
  /** Preview limitations and softer layout advice. */
  notes: string[];
  texts: FrameText[];
  png?: Uint8Array;
}
export interface PreviewSettings { fps: number; width: number; height: number; durationSeconds: number; language: string }

/** Bottom band reserved for the separately embedded subtitles while a voice is audible. */
export const SUBTITLE_BAND = 100;
const SIDE_MARGIN = 64;
const TOP_MARGIN = 48;
const MAX_FRAMES = 64;

const IDENTITY: Matrix = [1, 0, 0, 1, 0, 0];
const multiply = (m: Matrix, n: Matrix): Matrix => [
  m[0] * n[0] + m[2] * n[1], m[1] * n[0] + m[3] * n[1],
  m[0] * n[2] + m[2] * n[3], m[1] * n[2] + m[3] * n[3],
  m[0] * n[4] + m[2] * n[5] + m[4], m[1] * n[4] + m[3] * n[5] + m[5],
];
function bounds(m: Matrix, { x, y, width, height }: Box): Box {
  const points = [[x, y], [x + width, y], [x, y + height], [x + width, y + height]].map(([px, py]) => [m[0] * px + m[2] * py + m[4], m[1] * px + m[3] * py + m[5]]);
  const xs = points.map((p) => p[0]), ys = points.map((p) => p[1]);
  return { x: Math.min(...xs), y: Math.min(...ys), width: Math.max(...xs) - Math.min(...xs), height: Math.max(...ys) - Math.min(...ys) };
}
function intersection(a: Box, b: Box) {
  const width = Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x);
  const height = Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y);
  return width > 0 && height > 0 ? width * height : 0;
}

const number = (value: unknown, fallback = 0) => {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  const parsed = parseFloat(String(value ?? ""));
  return Number.isFinite(parsed) ? parsed : fallback;
};
const angle = (value: string) => {
  const amount = parseFloat(value);
  if (/rad$/.test(value)) return amount;
  if (/turn$/.test(value)) return amount * 2 * Math.PI;
  return (amount * Math.PI) / 180;
};
/** SVG attribute or CSS transform lists; percentages and 3D functions are ignored. */
function parseTransform(value: unknown): Matrix {
  let m = IDENTITY;
  if (typeof value !== "string") return m;
  for (const [, name, args] of value.matchAll(/([a-zA-Z]+)\s*\(([^)]*)\)/g)) {
    const raw = args.split(/[\s,]+/).filter(Boolean);
    const n = raw.map((arg) => (arg.endsWith("%") ? 0 : parseFloat(arg) || 0));
    let next: Matrix = IDENTITY;
    switch (name) {
      case "translate": next = [1, 0, 0, 1, n[0] ?? 0, n[1] ?? 0]; break;
      case "translateX": next = [1, 0, 0, 1, n[0] ?? 0, 0]; break;
      case "translateY": next = [1, 0, 0, 1, 0, n[0] ?? 0]; break;
      case "scale": next = [n[0] ?? 1, 0, 0, n[1] ?? n[0] ?? 1, 0, 0]; break;
      case "scaleX": next = [n[0] ?? 1, 0, 0, 1, 0, 0]; break;
      case "scaleY": next = [1, 0, 0, n[0] ?? 1, 0, 0]; break;
      case "matrix": if (n.length === 6) next = n as Matrix; break;
      case "rotate": {
        const a = /deg|rad|turn/.test(raw[0] ?? "") ? angle(raw[0]) : ((n[0] ?? 0) * Math.PI) / 180;
        const rotation: Matrix = [Math.cos(a), Math.sin(a), -Math.sin(a), Math.cos(a), 0, 0];
        next = raw.length === 3 ? multiply(multiply([1, 0, 0, 1, n[1], n[2]], rotation), [1, 0, 0, 1, -n[1], -n[2]]) : rotation;
        break;
      }
      case "skewX": next = [1, 0, Math.tan(angle(raw[0] ?? "0")), 1, 0, 0]; break;
      case "skewY": next = [1, Math.tan(angle(raw[0] ?? "0")), 0, 1, 0, 0]; break;
    }
    m = multiply(m, next);
  }
  return m;
}

// CJK, kana, Hangul and full-width forms.
const CJK = /[⺀-〿぀-ヿ㄀-ㇿ㐀-䶿一-鿿가-힯豈-﫿＀-￯]/u;
function charWidth(char: string, fontSize: number) {
  if (CJK.test(char)) return fontSize;
  if (/\s/.test(char)) return fontSize * 0.28;
  if (/[A-Z0-9]/.test(char)) return fontSize * 0.64;
  if (/[.,:;'!|il]/.test(char)) return fontSize * 0.3;
  return fontSize * 0.54;
}

/** Noto CJK subsets for exactly the characters on screen, keyed by family and characters. */
const fontCache = new Map<string, Promise<ArrayBuffer | null>>();
function cjkFamily(char: string, language: string) {
  if (/[぀-ヿㇰ-ㇿ]/u.test(char)) return "Noto Sans JP";
  if (/[가-힯ᄀ-ᇿ㄰-㆏]/u.test(char)) return "Noto Sans KR";
  if (/^ja/i.test(language)) return "Noto Sans JP";
  if (/^ko/i.test(language)) return "Noto Sans KR";
  if (/^zh-(?:hant|tw|hk|mo)/i.test(language)) return "Noto Sans TC";
  return "Noto Sans SC";
}
async function loadSubset(family: string, chars: string): Promise<ArrayBuffer | null> {
  const key = `${family}:${chars}`;
  let pending = fontCache.get(key);
  if (!pending) {
    pending = (async () => {
      try {
        const css = await fetch(`https://fonts.googleapis.com/css2?family=${encodeURIComponent(family)}&text=${encodeURIComponent(chars)}`,
          { signal: AbortSignal.timeout(6000) }).then((response) => (response.ok ? response.text() : ""));
        const url = css.match(/src:\s*url\(([^)]+)\)\s*format\(['"](?:opentype|truetype)['"]\)/)?.[1];
        if (!url) return null;
        const font = await fetch(url, { signal: AbortSignal.timeout(6000) });
        return font.ok ? await font.arrayBuffer() : null;
      } catch { return null; }
    })();
    if (fontCache.size > 64) fontCache.delete(fontCache.keys().next().value!);
    fontCache.set(key, pending);
    void pending.then((font) => { if (!font) fontCache.delete(key); });
  }
  return pending;
}
let geist: Buffer | null = null;
async function previewFonts(trees: Tree[], language: string) {
  geist ??= readFileSync(path.join(process.cwd(), "lib/podcast-video/fonts/Geist-Regular.ttf"));
  const byFamily = new Map<string, Set<string>>();
  const collect = (tree: Tree) => {
    if (typeof tree === "string") {
      for (const char of tree) if (CJK.test(char)) {
        const family = cjkFamily(char, language);
        if (!byFamily.has(family)) byFamily.set(family, new Set());
        byFamily.get(family)!.add(char);
      }
    } else tree.c.forEach(collect);
  };
  trees.forEach(collect);
  const subsets = await Promise.all([...byFamily].map(async ([family, chars]) => ({ family, data: await loadSubset(family, [...chars].sort().join("")) })));
  const fonts: Font[] = [{ name: "Geist", data: geist, weight: 400, style: "normal" }];
  for (const { family, data } of subsets) if (data) fonts.push({ name: family, data, weight: 400, style: "normal" });
  return { fonts, missingCjk: subsets.some(({ data }) => !data) };
}

/** Resvg's native build loads fonts from files: keep each font once under the temp directory. */
function fontFile(font: Font) {
  const bytes = Buffer.from(font.data as ArrayBuffer);
  const directory = path.join(tmpdir(), "podcast-preview-fonts");
  const file = path.join(directory, `${createHash("sha256").update(bytes).digest("hex").slice(0, 24)}.ttf`);
  if (!existsSync(file)) {
    mkdirSync(directory, { recursive: true });
    writeFileSync(file, bytes);
  }
  return file;
}

/** Bundles the project for QuickJS and renders each frame number to an element tree. */
async function elementTrees(files: Record<string, string>, data: unknown, phrases: unknown, frames: number[], settings: PreviewSettings) {
  const all: Record<string, string> = { ...files, ...PODCAST_VIDEO_SCAFFOLD, "src/data.json": JSON.stringify(data), [PODCAST_VIDEO_PHRASES]: JSON.stringify(phrases),
    "src/__preview.tsx": `import { PodcastVideo } from "./Video";\nimport { __renderFrames } from "remotion";\nexport const render = (frames: number[], settings: object) => __renderFrames(PodcastVideo, frames, settings);\n` };
  let bundle: string;
  try {
    bundle = (await bundlePodcastProject(all, "src/__preview.tsx", FRAME_RUNTIME)).outputFiles[0].text;
  } catch (error) {
    return { error: bundleIssues(error).map((issue) => `${issue.file ? `${issue.file}: ` : ""}${issue.message}`).join("\n") };
  }
  const budgetMs = Math.min(15_000, 2000 + frames.length * 200);
  const result = await new Promise<{ value?: string; error?: string }>((resolve) => {
    const worker = new Worker(path.join(process.cwd(), "lib/podcast-video/frame-worker.mjs"), { execArgv: [], env: {},
      workerData: { bundle, frames, budgetMs, settings: { fps: settings.fps, width: settings.width, height: settings.height,
        durationInFrames: Math.max(1, Math.ceil(settings.durationSeconds * settings.fps)) } },
      resourceLimits: { maxOldGenerationSizeMb: 256, stackSizeMb: 4 } });
    let done = false;
    const finish = (value: { value?: string; error?: string }) => {
      if (done) return;
      done = true; clearTimeout(timer); void worker.terminate(); resolve(value);
    };
    const timer = setTimeout(() => finish({ error: "Rendering the frames took too long; simplify per-frame work" }), budgetMs + 5000);
    worker.once("message", finish);
    worker.once("error", (error) => finish({ error: `Frame preview could not start: ${error.message}` }));
    worker.once("exit", () => finish({ error: "Frame preview stopped" }));
  });
  if (result.error !== undefined) return { error: /interrupted/i.test(result.error) ? "Rendering the frames took too long; simplify per-frame work" : result.error };
  return { frames: JSON.parse(result.value!) as { tree?: Tree[]; error?: string }[] };
}

const BLOCK_DISPLAYS = new Set([undefined, "block", "list-item", "table", "flow-root", "grid", "inline-grid", "contents"]);
const INLINE_TAGS = new Set(["span", "strong", "em", "b", "i", "small", "code", "label", "a", "sub", "sup", "mark"]);
const KEPT_TAGS = new Set(["p", "h1", "h2", "h3", "h4", "h5", "h6"]);
const DROPPED_STYLES = /^(?:animation|transition|willChange|cursor|pointerEvents|userSelect|zIndex|fontFamily|grid|isolation|contain|backdropFilter|mixBlendMode)/;
const LAYOUT_STYLES = /^(?:position|top|right|bottom|left|inset|margin|transform|opacity|flex|alignSelf|width|height|minWidth|minHeight|maxWidth|maxHeight|order)/;
const marker = (kind: 1 | 2, id: number) => `rgb(${kind}, ${id >> 8}, ${id & 255})`;
const markerPattern = /^rgb\((1|2),\s*(\d+),\s*(\d+)\)$/;

function expandInset(style: Record<string, unknown>) {
  if (style.inset === undefined) return;
  const parts = typeof style.inset === "number" ? [style.inset] : String(style.inset).split(/\s+/);
  const [top, right = top, bottom = top, left = right] = parts;
  for (const [key, value] of Object.entries({ top, right, bottom, left })) style[key] ??= value;
  delete style.inset;
}

/** Converts a rendered tree into Satori elements; SVGs and images become marker boxes. */
function toSatori(tree: Tree[], settings: PreviewSettings, families: string[]) {
  const svgs = new Map<number, Extract<Tree, object>>();
  let id = 0;
  const convert = (node: Tree): unknown => {
    if (typeof node === "string") return node;
    const style = { ...((node.p.style && typeof node.p.style === "object") ? node.p.style as Record<string, unknown> : {}) };
    if (style.display === "none") return null;
    expandInset(style);
    if (style.position === "fixed") style.position = "absolute";
    if (style.position === "sticky") style.position = "relative";
    const size = (key: "width" | "height", fallback: number) => style[key] ?? (node.p[key] !== undefined ? (typeof node.p[key] === "number" || /^[\d.]+$/.test(String(node.p[key])) ? number(node.p[key]) : node.p[key]) : fallback);
    if (node.t === "svg" || node.t === "img") {
      id += 1;
      const kind = node.t === "svg" ? 1 : 2;
      if (kind === 1) svgs.set(id, node);
      const layout = Object.fromEntries(Object.entries(style).filter(([key]) => LAYOUT_STYLES.test(key)));
      return { type: "div", key: `m${id}`, props: { style: { ...layout, display: "flex", width: size("width", kind === 1 ? 300 : 320), height: size("height", kind === 1 ? 150 : 200),
        backgroundColor: marker(kind, id) } } };
    }
    const converted = node.c.map(convert);
    const children = converted.filter((child) => child !== null && child !== "");
    const hasText = children.some((child) => typeof child === "string" && child.trim());
    const hasElements = children.some((child) => typeof child !== "string");
    for (const key of Object.keys(style)) if (DROPPED_STYLES.test(key)) delete style[key];
    const display = node.p.style && typeof node.p.style === "object" ? (node.p.style as Record<string, unknown>).display as string | undefined : undefined;
    if (display !== "flex" && display !== "inline-flex") {
      style.display = "flex";
      if (hasText && hasElements) { style.flexDirection ??= "row"; style.flexWrap ??= "wrap"; style.alignItems ??= "baseline"; }
      else if (BLOCK_DISPLAYS.has(display) && !INLINE_TAGS.has(node.t)) style.flexDirection ??= "column";
    } else style.display = "flex";
    // Painting order follows z-index among siblings, as positioned elements do in WebKit.
    const z = (child: Tree) => (typeof child === "object" && child.p.style && typeof child.p.style === "object" ? number((child.p.style as Record<string, unknown>).zIndex, 0) : 0);
    const order = node.c.map((child, index) => ({ child: converted[index], z: z(child), index })).filter(({ child }) => child !== null && child !== "");
    order.sort((a, b) => a.z - b.z || a.index - b.index);
    const type = KEPT_TAGS.has(node.t) ? node.t : INLINE_TAGS.has(node.t) ? "span" : "div";
    return { type, props: { style, children: order.map(({ child }) => child) } };
  };
  const root = { type: "div", props: { style: { position: "relative", display: "flex", flexDirection: "column", width: settings.width, height: settings.height,
    backgroundColor: "#ffffff", color: "#000000", fontSize: 16, overflow: "hidden", fontFamily: families.map((f) => `"${f}"`).join(", ") },
  children: tree.map(convert).filter((child) => child !== null) } };
  return { root, svgs };
}

const KEEP_CAMEL = new Set(["viewBox", "preserveAspectRatio", "gradientUnits", "gradientTransform", "patternUnits", "patternContentUnits", "patternTransform",
  "markerWidth", "markerHeight", "markerUnits", "refX", "refY", "pathLength", "textLength", "lengthAdjust", "startOffset", "clipPathUnits", "maskUnits",
  "maskContentUnits", "spreadMethod", "stdDeviation", "filterUnits", "primitiveUnits", "baseFrequency", "numOctaves", "tableValues"]);
const escape = (value: string) => value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const kebab = (name: string) => name.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);
function styleText(style: unknown) {
  if (!style || typeof style !== "object") return "";
  return Object.entries(style as Record<string, unknown>).filter(([, value]) => typeof value === "string" || typeof value === "number")
    .map(([key, value]) => `${kebab(key)}:${typeof value === "number" && /^(?:fontSize|letterSpacing)$/.test(key) ? `${value}px` : value}`).join(";");
}
function attributes(props: Record<string, unknown>, skip: Set<string> = new Set()) {
  let out = "";
  for (const [key, value] of Object.entries(props)) {
    if (skip.has(key) || key === "className" || key === "class" || key === "style" || key === "dangerouslySetInnerHTML") continue;
    if (typeof value !== "string" && typeof value !== "number" && typeof value !== "boolean" && !Array.isArray(value)) continue;
    const name = key === "xlinkHref" ? "xlink:href" : KEEP_CAMEL.has(key) ? key : kebab(key);
    out += ` ${name}="${escape(Array.isArray(value) ? value.join(" ") : String(value))}"`;
  }
  const style = styleText(props.style);
  return style ? `${out} style="${escape(style)}"` : out;
}
function svgMarkup(node: Tree): string {
  if (typeof node === "string") return escape(node);
  if (node.t === "foreignObject") return "";
  return `<${node.t}${attributes(node.p)}>${node.c.map(svgMarkup).join("")}</${node.t}>`;
}

const SKIPPED_SVG = new Set(["defs", "clipPath", "mask", "marker", "pattern", "symbol", "linearGradient", "radialGradient", "filter", "foreignObject", "title", "desc"]);
const styleOf = (node: Extract<Tree, object>, key: string) => (node.p.style && typeof node.p.style === "object" ? (node.p.style as Record<string, unknown>)[key] : undefined) ?? node.p[key];
function viewBoxMatrix(node: Extract<Tree, object>, width: number, height: number): Matrix {
  const box = String(node.p.viewBox ?? "").split(/[\s,]+/).map(Number);
  if (box.length !== 4 || box.some((v) => !Number.isFinite(v)) || box[2] <= 0 || box[3] <= 0) return IDENTITY;
  const [minX, minY, vw, vh] = box;
  const [align = "xMidYMid", mode = "meet"] = String(node.p.preserveAspectRatio ?? "xMidYMid meet").split(/\s+/);
  let sx = width / vw, sy = height / vh;
  if (align !== "none") sx = sy = mode === "slice" ? Math.max(sx, sy) : Math.min(sx, sy);
  const tx = align.includes("xMid") ? (width - vw * sx) / 2 : align.includes("xMax") ? width - vw * sx : 0;
  const ty = align.includes("YMid") ? (height - vh * sy) / 2 : align.includes("YMax") ? height - vh * sy : 0;
  return [sx, 0, 0, sy, tx - minX * sx, ty - minY * sy];
}
function fillAlpha(fill: unknown) {
  const value = String(fill ?? "").trim().toLowerCase();
  if (value === "none" || value === "transparent") return 0;
  const rgb = value.match(/^(?:rgb|hsl)a?\(([^)]*)\)$/);
  if (rgb) {
    const alpha = rgb[1].split(/[\s,/]+/).filter(Boolean)[3];
    return alpha === undefined ? 1 : alpha.endsWith("%") ? parseFloat(alpha) / 100 : parseFloat(alpha);
  }
  const hex = value.match(/^#(?:[0-9a-f]{3}([0-9a-f])|[0-9a-f]{6}([0-9a-f]{2}))$/);
  return hex ? parseInt(hex[1] ? hex[1] + hex[1] : hex[2], 16) / 255 : 1;
}

/** Text lines and image boxes inside an inline SVG, estimated from attributes. */
function svgGeometry(node: Extract<Tree, object>, base: Matrix, width: number, height: number, opacity: number) {
  const texts: (FrameText & { opacity: number })[] = [];
  const images: Box[] = [];
  const textOf = (child: Tree): string => (typeof child === "string" ? child : child.c.map(textOf).join(""));
  const walk = (item: Tree, m: Matrix, alpha: number, inherited: { fontSize: number; anchor: string; baseline: string; fill: unknown }) => {
    if (typeof item === "string" || SKIPPED_SVG.has(item.t)) return;
    if (styleOf(item, "display") === "none" || styleOf(item, "visibility") === "hidden") return;
    const local = alpha * number(styleOf(item, "opacity"), 1);
    const css = item.p.style && typeof item.p.style === "object" ? (item.p.style as Record<string, unknown>).transform : undefined;
    let matrix = multiply(multiply(m, parseTransform(item.p.transform)), parseTransform(css));
    const style = {
      fontSize: number(styleOf(item, "fontSize"), inherited.fontSize),
      anchor: String(styleOf(item, "textAnchor") ?? inherited.anchor),
      baseline: String(styleOf(item, "dominantBaseline") ?? styleOf(item, "alignmentBaseline") ?? inherited.baseline),
      fill: styleOf(item, "fill") ?? inherited.fill,
    };
    if (item.t === "svg" && item !== node) matrix = multiply(matrix, [1, 0, 0, 1, number(item.p.x), number(item.p.y)]);
    if (item.t === "image") {
      images.push(bounds(matrix, { x: number(item.p.x), y: number(item.p.y), width: number(item.p.width), height: number(item.p.height) }));
      return;
    }
    if (item.t === "text") {
      const visible = local * fillAlpha(style.fill) * number(styleOf(item, "fillOpacity"), 1);
      const lines: { text: string; x: number; y: number }[] = [];
      let x = number(Array.isArray(item.p.x) ? item.p.x[0] : String(item.p.x ?? "0").split(/[\s,]+/)[0]);
      let y = number(Array.isArray(item.p.y) ? item.p.y[0] : String(item.p.y ?? "0").split(/[\s,]+/)[0]) + number(item.p.dy);
      let current = { text: "", x, y };
      for (const child of item.c) {
        if (typeof child === "object" && child.t === "tspan" && (child.p.x !== undefined || child.p.y !== undefined || child.p.dy !== undefined)) {
          if (current.text.trim()) lines.push(current);
          x = child.p.x !== undefined ? number(child.p.x) : x;
          y = (child.p.y !== undefined ? number(child.p.y) : y) + number(child.p.dy);
          current = { text: textOf(child), x, y };
          lines.push(current);
          current = { text: "", x, y };
        } else current.text += textOf(child);
      }
      if (current.text.trim()) lines.push(current);
      const spacing = number(styleOf(item, "letterSpacing"));
      for (const line of lines) {
        const text = line.text.replace(/\s+/g, " ").trim();
        if (!text) continue;
        const lineWidth = [...text].reduce((sum, char) => sum + charWidth(char, style.fontSize) + spacing, 0);
        const left = style.anchor === "middle" ? line.x - lineWidth / 2 : style.anchor === "end" ? line.x - lineWidth : line.x;
        const shift = /middle|central/.test(style.baseline) ? 0.35 : /hanging|text-before-edge|text-top/.test(style.baseline) ? 0.8 : 0;
        const box = bounds(matrix, { x: left, y: line.y + (shift - 0.75) * style.fontSize, width: lineWidth, height: style.fontSize * 0.95 });
        texts.push({ ...box, text, fontSize: style.fontSize * Math.sqrt(Math.abs(matrix[0] * matrix[3] - matrix[1] * matrix[2])), opacity: visible });
      }
      return;
    }
    for (const child of item.c) walk(child, matrix, local, style);
  };
  walk(node, multiply(base, viewBoxMatrix(node, width, height)), opacity, {
    fontSize: number(styleOf(node, "fontSize"), 16), anchor: String(styleOf(node, "textAnchor") ?? "start"), baseline: "auto", fill: styleOf(node, "fill") ?? "black" });
  return { texts, images };
}

const parseAttributes = (source: string) => Object.fromEntries([...source.matchAll(/([\w:-]+)="([^"]*)"/g)].map(([, key, value]) => [key, value]));
const unescape = (text: string) => text.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&#39;/g, "'").replace(/&amp;/g, "&");

/** Reads Satori's SVG: word boxes and marker rects, then splices the real SVGs and artwork placeholders in. */
function analyse(svg: string, svgs: Map<number, Extract<Tree, object>>) {
  const words: { text: string; box: Box; fontSize: number; key: string; opacity: number }[] = [];
  const texts: (FrameText & { opacity: number })[] = [];
  const images: Box[] = [];
  const replacements: { start: number; end: number; markup: string }[] = [];
  const stack: { name: string; opacity: number; skip: boolean }[] = [{ name: "root", opacity: 1, skip: false }];
  let openText: { attrs: Record<string, string>; content: string; opacity: number } | null = null;
  for (const match of svg.matchAll(/<(\/?)([a-zA-Z][\w:-]*)([^>]*?)(\/?)>|([^<]+)/g)) {
    const [whole, closing, name, rawAttrs, selfClosing, content] = match;
    const parent = stack[stack.length - 1];
    if (content !== undefined) { if (openText) openText.content += content; continue; }
    if (closing) {
      if (name === "text" && openText) {
        const { attrs } = openText;
        const fontSize = number(attrs["font-size"], 16);
        const m = attrs.transform ? parseTransform(attrs.transform) : IDENTITY;
        const box = bounds(m, { x: number(attrs.x), y: number(attrs.y) - 0.78 * fontSize, width: number(attrs.width), height: fontSize * 0.98 });
        words.push({ text: unescape(openText.content), box, fontSize: fontSize * Math.sqrt(Math.abs(m[0] * m[3] - m[1] * m[2])), key: `${attrs.y}|${attrs.transform ?? ""}|${fontSize}`,
          opacity: openText.opacity * fillAlpha(attrs.fill) * number(attrs["fill-opacity"], 1) });
        openText = null;
      }
      if (stack.length > 1 && stack[stack.length - 1].name === name) stack.pop();
      continue;
    }
    const attrs = parseAttributes(rawAttrs);
    const opacity = parent.opacity * number(attrs.opacity, 1);
    const skip = parent.skip || ["mask", "clipPath", "defs", "pattern", "linearGradient", "radialGradient", "filter"].includes(name);
    if (!skip && name === "text") openText = { attrs, content: "", opacity };
    const found = !skip && name === "rect" ? String(attrs.fill ?? "").match(markerPattern) : null;
    if (found) {
      const kind = Number(found[1]), id = Number(found[2]) * 256 + Number(found[3]);
      const m = attrs.transform ? parseTransform(attrs.transform) : IDENTITY;
      const box: Box = { x: number(attrs.x), y: number(attrs.y), width: number(attrs.width), height: number(attrs.height) };
      const wrapper = ["transform", "clip-path", "mask"].filter((key) => attrs[key]).map((key) => ` ${key}="${attrs[key]}"`).join("");
      const start = match.index!, end = start + whole.length;
      if (kind === 2) {
        images.push(bounds(m, box));
        const { x, y, width, height } = box;
        replacements.push({ start, end, markup: `<g${wrapper}><rect x="${x}" y="${y}" width="${width}" height="${height}" fill="#D3DED9" stroke="#8FA69D" stroke-width="2"/>`
          + `<path d="M${x} ${y}L${x + width} ${y + height}M${x + width} ${y}L${x} ${y + height}" stroke="#8FA69D" stroke-width="2"/></g>` });
      } else {
        const node = svgs.get(id);
        if (node) {
          const geometry = svgGeometry(node, multiply(m, [1, 0, 0, 1, box.x, box.y]), box.width, box.height, opacity);
          texts.push(...geometry.texts);
          images.push(...geometry.images);
          const overflow = styleOf(node, "overflow") === "visible" ? "visible" : "hidden";
          const inner = attributes(node.p, new Set(["width", "height", "x", "y", "viewBox", "preserveAspectRatio", "overflow", "xmlns"]));
          const viewBox = node.p.viewBox ? ` viewBox="${escape(String(node.p.viewBox))}"` : "";
          const aspect = node.p.preserveAspectRatio ? ` preserveAspectRatio="${escape(String(node.p.preserveAspectRatio))}"` : "";
          replacements.push({ start, end, markup: `<g${wrapper}><svg x="${box.x}" y="${box.y}" width="${box.width}" height="${box.height}"${viewBox}${aspect} overflow="${overflow}"${inner}>`
            + `${node.c.map(svgMarkup).join("")}</svg></g>` });
        }
      }
    }
    if (!selfClosing) stack.push({ name, opacity, skip });
  }
  // Satori emits one <text> per word: join neighbouring words of the same run into lines.
  for (const word of words) {
    const last = texts[texts.length - 1] as (FrameText & { opacity: number; key?: string }) | undefined;
    if (last && last.key === word.key && Math.abs(last.x + last.width - word.box.x) < 2) {
      last.width = word.box.x + word.box.width - last.x;
      last.text += word.text;
      last.opacity = Math.max(last.opacity, word.opacity);
    } else texts.push(Object.assign({ ...word.box, text: word.text, fontSize: word.fontSize, opacity: word.opacity }, { key: word.key }));
  }
  let painted = svg;
  for (const { start, end, markup } of replacements.sort((a, b) => b.start - a.start)) painted = painted.slice(0, start) + markup + painted.slice(end);
  painted = painted.replace(/^<svg /, "<svg xmlns:xlink=\"http://www.w3.org/1999/xlink\" ");
  return { texts: texts.map(({ text, x, y, width, height, fontSize, opacity }) => ({ text: text.trim(), x, y, width, height, fontSize, opacity })).filter((t) => t.text), images, painted };
}

const describe = (text: FrameText) => `"${text.text.slice(0, 40)}" (x ${Math.round(text.x)}–${Math.round(text.x + text.width)}, y ${Math.round(text.y)}–${Math.round(text.y + text.height)})`;

function layoutIssues(texts: (FrameText & { opacity: number })[], images: Box[], frame: PreviewFrame, settings: PreviewSettings) {
  const issues: string[] = [];
  const notes: string[] = [];
  const visible = texts.filter((text) => text.opacity >= 0.35 && text.width > 0 && text.height > 0);
  for (let i = 0; i < visible.length; i += 1) {
    for (let j = i + 1; j < visible.length; j += 1) {
      const a = visible[i], b = visible[j];
      const shared = intersection(a, b);
      if (shared > 0.15 * Math.min(a.width * a.height, b.width * b.height)) issues.push(`Text overlaps text: ${describe(a)} and ${describe(b)}`);
    }
    const text = visible[i];
    for (const image of images) {
      if (intersection(text, image) > 0.2 * text.width * text.height) issues.push(`Text covers artwork: ${describe(text)} over the image at x ${Math.round(image.x)}, y ${Math.round(image.y)}`);
    }
    if (text.x < -2 || text.y < -2 || text.x + text.width > settings.width + 2 || text.y + text.height > settings.height + 2) {
      issues.push(`Text is cut off by the canvas edge: ${describe(text)}`);
    } else if (frame.speaking && text.y + text.height > settings.height - SUBTITLE_BAND + 4) {
      issues.push(`Text enters the subtitle area (bottom ${SUBTITLE_BAND}px) while the voice plays: ${describe(text)}`);
    } else if (text.x < SIDE_MARGIN - 16 || text.x + text.width > settings.width - SIDE_MARGIN + 16 || text.y < TOP_MARGIN - 16) {
      notes.push(`Text outside the safe margins: ${describe(text)}`);
    }
    if (text.fontSize < 17) notes.push(`Text smaller than 18px is hard to read on a phone: ${describe(text)}`);
  }
  return { issues: [...new Set(issues)].slice(0, 12), notes: [...new Set(notes)].slice(0, 8) };
}

/**
 * Renders the composition at each time and reports overlapping, clipped or subtitle-covering text.
 * `data` is the episode's data.json; `phrases` its phrases.json. PNGs are only drawn when requested.
 */
export async function previewPodcastFrames(files: Record<string, string>, data: unknown, phrases: unknown, frames: PreviewFrame[],
  settings: PreviewSettings, options: { png?: boolean } = {}): Promise<{ error: string } | { frames: FrameReport[] }> {
  const selected = frames.slice(0, MAX_FRAMES);
  const rendered = await elementTrees(files, data, phrases, selected.map((f) => Math.max(0, Math.round(f.seconds * settings.fps))), settings);
  if ("error" in rendered) return { error: rendered.error! };
  const { fonts, missingCjk } = await previewFonts(rendered.frames.flatMap((f) => f.tree ?? []), settings.language);
  const families = fonts.map((font) => font.name);
  const shared: string[] = [];
  if (Object.keys(files).some((file) => file.endsWith(".css"))) shared.push("CSS files are not applied in previews; use inline styles for layout.");
  if (missingCjk) shared.push("A CJK font could not be loaded; CJK text is approximated.");
  const reports: FrameReport[] = [];
  for (const [index, frame] of selected.entries()) {
    const result = rendered.frames[index];
    if (!result?.tree) {
      reports.push({ seconds: frame.seconds, issues: [`The composition throws at ${frame.seconds.toFixed(2)}s: ${result?.error ?? "no output"}`], notes: shared, texts: [] });
      continue;
    }
    const { root, svgs } = toSatori(result.tree, settings, families);
    const styleErrors = new Set<string>();
    let svg: string;
    try {
      svg = await satori(root as never, { width: settings.width, height: settings.height, fonts, embedFont: false,
        onStyleError: (error) => { if (styleErrors.size < 4) styleErrors.add(error.message.split("\n")[0].slice(0, 160)); } });
    } catch (error) {
      reports.push({ seconds: frame.seconds, issues: [], texts: [],
        notes: [...shared, `The preview could not lay out this frame (${error instanceof Error ? error.message.slice(0, 200) : "unknown error"}); check it on device.`] });
      continue;
    }
    const { texts, images, painted } = analyse(svg, svgs);
    const { issues, notes } = layoutIssues(texts, images, frame, settings);
    const report: FrameReport = { seconds: frame.seconds, issues, notes: [...shared, ...notes, ...[...styleErrors].map((message) => `Preview ignored a style: ${message}`)],
      texts: texts.filter((text) => text.opacity >= 0.35).slice(0, 40).map(({ text, x, y, width, height, fontSize }) => ({ text, fontSize: Math.round(fontSize),
        x: Math.round(x), y: Math.round(y), width: Math.round(width), height: Math.round(height) })) };
    if (options.png) {
      report.png = new Resvg(painted, { fitTo: { mode: "width", value: 960 }, font: { fontFiles: fonts.map(fontFile),
        loadSystemFonts: false, defaultFontFamily: "Geist", sansSerifFamily: "Geist", serifFamily: "Geist" } }).render().asPng();
    }
    reports.push(report);
  }
  return { frames: reports };
}
