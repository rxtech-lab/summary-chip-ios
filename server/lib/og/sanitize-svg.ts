import { DOMParser } from "linkedom";

/**
 * Strict allow-list SVG sanitiser for model-written decoration.
 *
 * The input is parsed and a brand-new document is serialised from the allowed elements and
 * attributes only, with every value re-escaped — nothing from the source is copied verbatim.
 * Scripts, foreignObject, <style>, <image>, <use>, animation, event handlers, external/`javascript:`
 * references and CSS are all dropped because they are simply not on the list.
 */

const ELEMENTS = new Map([
  "svg", "g", "defs", "linearGradient", "radialGradient", "stop", "path", "circle", "ellipse",
  "rect", "line", "polyline", "polygon", "clipPath",
].map((name) => [name.toLowerCase(), name]));

const ATTRIBUTES = new Map([
  "id", "viewBox", "width", "height", "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry",
  "fx", "fy", "d", "points", "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width",
  "stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-dasharray", "stroke-miterlimit",
  "opacity", "transform", "offset", "stop-color", "stop-opacity", "gradientUnits",
  "gradientTransform", "spreadMethod", "clip-path", "clip-rule", "clipPathUnits", "preserveAspectRatio",
].map((name) => [name.toLowerCase(), name]));

const MAX_INPUT = 64_000;
const MAX_ELEMENTS = 300;
const MAX_DEPTH = 12;
const LONG_VALUE_ATTRIBUTES = new Set(["d", "points"]);

function escapeAttribute(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function safeValue(name: string, value: string): string | null {
  const trimmed = value.trim();
  if (trimmed.length > (LONG_VALUE_ATTRIBUTES.has(name) ? 20_000 : 500)) return null;
  // Only local fragment references: url(#id). Anything else containing "url(" is rejected.
  const withoutLocalRefs = trimmed.replace(/url\(\s*#[A-Za-z][\w.-]*\s*\)/g, "");
  if (/url\s*\(|javascript:|data:|expression|@import|[<>\\]/i.test(withoutLocalRefs)) return null;
  if (name === "id" && !/^[A-Za-z][\w.-]{0,63}$/.test(trimmed)) return null;
  return trimmed;
}

interface WalkState {
  count: number;
  drawables: number;
}

const DRAWABLE = new Set(["path", "circle", "ellipse", "rect", "line", "polyline", "polygon"]);

function serialize(element: Element, depth: number, state: WalkState): string {
  const name = ELEMENTS.get(element.tagName.toLowerCase());
  if (!name || depth > MAX_DEPTH || state.count >= MAX_ELEMENTS) return "";
  state.count += 1;
  if (DRAWABLE.has(name.toLowerCase())) state.drawables += 1;
  const attributes: string[] = [];
  for (const attribute of Array.from(element.attributes)) {
    const canonical = ATTRIBUTES.get(attribute.name.toLowerCase());
    if (!canonical || depth === 0 && (canonical === "width" || canonical === "height" || canonical === "viewBox")) continue;
    const value = safeValue(canonical, attribute.value);
    if (value !== null) attributes.push(`${canonical}="${escapeAttribute(value)}"`);
  }
  const children = Array.from(element.children).map((child) => serialize(child, depth + 1, state)).join("");
  const open = `<${name}${attributes.length ? ` ${attributes.join(" ")}` : ""}`;
  return children ? `${open}>${children}</${name}>` : `${open}/>`;
}

function sanitizeViewBox(value: string | null): string {
  if (!value) return "0 0 1200 630";
  const numbers = value.trim().split(/[\s,]+/).map(Number);
  if (numbers.length !== 4 || numbers.some((number) => !Number.isFinite(number)) || numbers[2] <= 0 || numbers[3] <= 0) {
    return "0 0 1200 630";
  }
  return numbers.join(" ");
}

/** Returns a safe standalone SVG string, or null when the input is unusable. */
export function sanitizeSvg(input: string | null | undefined): string | null {
  if (!input || input.length > MAX_INPUT) return null;
  const start = input.search(/<svg[\s>]/i);
  const end = input.toLowerCase().lastIndexOf("</svg>");
  if (start < 0 || end < start) return null;
  const markup = input.slice(start, end + "</svg>".length);
  let document: Document;
  try {
    document = new DOMParser().parseFromString(markup, "image/svg+xml") as unknown as Document;
  } catch {
    return null;
  }
  const root = document.documentElement;
  if (!root || root.tagName.toLowerCase() !== "svg") return null;
  const state: WalkState = { count: 0, drawables: 0 };
  const body = Array.from(root.children).map((child) => serialize(child, 1, state)).join("");
  if (state.drawables === 0) return null;
  const rootAttributes: string[] = [];
  for (const attribute of Array.from(root.attributes)) {
    const canonical = ATTRIBUTES.get(attribute.name.toLowerCase());
    if (!canonical || canonical === "width" || canonical === "height" || canonical === "viewBox") continue;
    const value = safeValue(canonical, attribute.value);
    if (value !== null) rootAttributes.push(`${canonical}="${escapeAttribute(value)}"`);
  }
  const viewBox = sanitizeViewBox(root.getAttribute("viewBox") ?? root.getAttribute("viewbox"));
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${viewBox}" width="1200" height="630" preserveAspectRatio="xMidYMid slice"${rootAttributes.length ? ` ${rootAttributes.join(" ")}` : ""}>${body}</svg>`;
}
