import { Readability } from "@mozilla/readability";
import { parseHTML } from "linkedom";

export interface HtmlExtraction {
  title: string | null;
  siteName: string | null;
  lang: string | null;
  imageUrl: string | null;
  text: string;
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
  try {
    const article = new Readability(document.cloneNode(true) as Document, { charThreshold: 200 }).parse();
    text = normalizeWhitespace(article?.textContent ?? "");
    articleTitle = article?.title?.trim() || null;
  } catch {
    text = "";
  }
  if (text.length < 200) {
    for (const selector of ["script", "style", "noscript", "nav", "header", "footer", "aside", "form"]) {
      document.querySelectorAll(selector).forEach((node) => node.remove());
    }
    const bodyText = normalizeWhitespace(document.body?.textContent ?? "");
    if (bodyText.length > text.length) text = bodyText;
  }
  return { title: title ?? articleTitle, siteName, lang, imageUrl, text };
}
