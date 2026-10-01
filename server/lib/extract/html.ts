import { Readability } from "@mozilla/readability";
import { parseHTML } from "linkedom";

export interface HtmlExtraction {
  title: string | null;
  siteName: string | null;
  lang: string | null;
  imageUrl: string | null;
  text: string;
  /** The main content as simplified HTML (links, images, headings, lists, tables), or null. */
  html: string | null;
}

function meta(document: Document, ...names: string[]): string | null {
  for (const name of names) {
    const element = document.querySelector(`meta[property="${name}"], meta[name="${name}"]`);
    const content = element?.getAttribute("content")?.trim();
    if (content) return content;
  }
  return null;
}

export function normalizeWhitespace(text: string): string {
  return text
    .replace(/\r\n?/g, "\n")
    .replace(/[ \t ]+/g, " ")
    .replace(/ *\n */g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** Characters of simplified HTML kept for the document rewrite. */
export const RICH_HTML_LIMIT = 150_000;

/** Structure worth keeping for a readable document; every other element is unwrapped to its children. */
const KEPT_TAGS = new Set([
  "h1", "h2", "h3", "h4", "h5", "h6", "p", "br", "hr", "a", "img", "figure", "figcaption",
  "ul", "ol", "li", "blockquote", "pre", "code", "em", "i", "strong", "b", "del", "s", "sup", "sub",
  "table", "thead", "tbody", "tr", "th", "td", "dl", "dt", "dd",
]);
const DROPPED_TAGS = "script, style, noscript, template, svg, canvas, form, input, button, select, textarea, nav, aside, footer, iframe, object, embed, audio, source, track, link, meta";
const KEPT_ATTRIBUTES: Record<string, string[]> = {
  a: ["href", "title"],
  img: ["src", "alt", "title"],
  td: ["colspan", "rowspan"],
  th: ["colspan", "rowspan"],
  code: ["class"],
};

function absoluteUrl(value: string | null | undefined, base: string): string | null {
  const trimmed = value?.trim();
  if (!trimmed || trimmed.startsWith("#")) return null;
  try {
    const url = new URL(trimmed, base);
    return url.protocol === "http:" || url.protocol === "https:" || url.protocol === "mailto:" ? url.toString() : null;
  } catch {
    return null;
  }
}

/** The best candidate of a lazy-loaded image: `src`, its lazy-load stand-ins, or the largest `srcset` entry. */
function imageSource(image: Element): string | null {
  for (const name of ["data-src", "data-original", "data-lazy-src", "src"]) {
    const value = image.getAttribute(name);
    if (value && !value.startsWith("data:")) return value;
  }
  const srcset = image.getAttribute("srcset") ?? image.getAttribute("data-srcset");
  return srcset?.split(",").map((entry) => entry.trim().split(/\s+/)[0]).filter(Boolean).pop() ?? null;
}

/**
 * Reduces article HTML to plain structural markup for the document agent: absolute link and image
 * URLs, no scripts, styles, classes or layout wrappers. The output only ever reaches the model.
 */
export function simplifyHtml(html: string, baseUrl: string): string | null {
  const { document } = parseHTML(`<!doctype html><html><body>${html}</body></html>`) as unknown as { document: Document };
  const body = document.body;
  if (!body) return null;
  body.querySelectorAll(DROPPED_TAGS).forEach((node) => node.remove());
  body.querySelectorAll("picture").forEach((picture) => {
    const image = picture.querySelector("img");
    if (image) picture.replaceWith(image);
    else picture.remove();
  });
  for (const element of [...body.querySelectorAll("*")].reverse()) {
    const tag = element.tagName.toLowerCase();
    if (!KEPT_TAGS.has(tag)) {
      element.replaceWith(...element.childNodes);
      continue;
    }
    const keep = KEPT_ATTRIBUTES[tag] ?? [];
    const values = Object.fromEntries(keep.map((name) => [name, element.getAttribute(name)]));
    if (tag === "img") values.src = imageSource(element);
    for (const name of element.getAttributeNames()) element.removeAttribute(name);
    if (tag === "a") values.href = absoluteUrl(values.href, baseUrl);
    if (tag === "img") {
      values.src = absoluteUrl(values.src, baseUrl);
      if (!values.src) {
        element.remove();
        continue;
      }
    }
    if (tag === "code" && !/^(lang|language)-[\w+#-]+$/.test(values.class ?? "")) values.class = null;
    for (const [name, value] of Object.entries(values)) if (value) element.setAttribute(name, value);
  }
  // One block per line, so the agent's parts split between blocks; whitespace in <pre> is code.
  const simplified = body.innerHTML
    .split(/(<pre>[\s\S]*?<\/pre>)/)
    .map((segment) => segment.startsWith("<pre>") ? `${segment}\n` : segment
      .replace(/\s+/g, " ")
      .replace(/<(p|li|h[1-6]|figcaption|blockquote|td|th)> ?<\/\1>/g, "")
      .replace(/ ?(<\/(?:p|h[1-6]|li|ul|ol|blockquote|figure|table|tr|dl|dt|dd)>|<br>|<hr>) ?/g, "$1\n")
      .trim())
    .join("")
    .trim();
  return simplified ? simplified.slice(0, RICH_HTML_LIMIT) : null;
}

/** Main-content extraction with Readability over a linkedom DOM (no jsdom, serverless friendly). */
export function extractHtml(html: string, pageUrl: string): HtmlExtraction {
  const { document } = parseHTML(html) as unknown as { document: Document };
  const title = meta(document, "og:title", "twitter:title") ?? (document.querySelector("title")?.textContent?.trim() || null);
  const siteName = meta(document, "og:site_name", "application-name") ?? null;
  const lang = document.documentElement?.getAttribute("lang")?.trim() || meta(document, "og:locale")?.replace("_", "-") || null;
  let imageUrl = meta(document, "og:image", "og:image:url", "twitter:image");
  if (imageUrl) {
    try {
      imageUrl = new URL(imageUrl, pageUrl).toString();
    } catch {
      imageUrl = null;
    }
  }

  let text = "";
  let articleTitle: string | null = null;
  let articleHtml: string | null = null;
  try {
    const article = new Readability(document.cloneNode(true) as Document, { charThreshold: 200 }).parse();
    text = normalizeWhitespace(article?.textContent ?? "");
    articleTitle = article?.title?.trim() || null;
    articleHtml = article?.content ?? null;
  } catch {
    text = "";
  }
  if (text.length < 200) {
    for (const selector of ["script", "style", "noscript", "nav", "header", "footer", "aside", "form"]) {
      document.querySelectorAll(selector).forEach((node) => node.remove());
    }
    const bodyText = normalizeWhitespace(document.body?.textContent ?? "");
    if (bodyText.length > text.length) {
      text = bodyText;
      articleHtml = document.body?.innerHTML ?? null;
    }
  }
  const rich = articleHtml ? simplifyHtml(articleHtml, pageUrl) : null;
  return { title: title ?? articleTitle, siteName, lang, imageUrl, text, html: rich };
}
