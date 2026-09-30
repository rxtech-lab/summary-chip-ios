import type { SummarySource } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { decodeText, fetchPublicDocument } from "./fetch";
import { extractHtml, normalizeWhitespace } from "./html";
import { extractPdfText } from "./pdf";

export interface ExtractedContent {
  source: SummarySource;
  text: string;
  sourceUrl: string | null;
  sourceTitle: string | null;
  siteName: string | null;
  lang: string | null;
  imageUrl: string | null;
}

/** Characters of source text sent to the model. */
export const LLM_TEXT_LIMIT = 60_000;
/** Characters persisted as a short excerpt for the library-wide chat's `getSummary` tool. */
export const EXCERPT_LIMIT = 8_000;
/** Characters of original text stored with a summary. */
export const SOURCE_TEXT_LIMIT = 500_000;

const MIN_TEXT_LENGTH = 20;

export function hostOf(url: string | null | undefined): string | null {
  if (!url) return null;
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return null;
  }
}

function assertEnoughText(text: string): void {
  if (text.replace(/\s/g, "").length < MIN_TEXT_LENGTH) {
    throw new ApiError(422, "NO_CONTENT", "Not enough readable text was found to summarise");
  }
}

/** Fetches and extracts a web page (HTML, PDF or plain text responses). */
export async function extractFromUrl(url: string): Promise<ExtractedContent> {
  const document = await fetchPublicDocument(url, { maxBytes: 10 * 1024 * 1024 });
  const finalUrl = document.url.toString();
  if (document.contentType === "application/pdf" || document.contentType === "application/x-pdf") {
    const pdf = await extractPdfText(document.bytes);
    return { source: "pdf", text: pdf.text, sourceUrl: url, sourceTitle: pdf.title, siteName: hostOf(finalUrl), lang: null, imageUrl: null };
  }
  if (document.contentType.startsWith("text/plain")) {
    const text = normalizeWhitespace(decodeText(document.bytes, document.charset));
    assertEnoughText(text);
    return { source: "web", text, sourceUrl: url, sourceTitle: null, siteName: hostOf(finalUrl), lang: null, imageUrl: null };
  }
  if (!document.contentType.includes("html") && !document.contentType.includes("xml")) {
    throw new ApiError(422, "UNSUPPORTED_CONTENT", `Pages of type ${document.contentType} cannot be summarised`);
  }
  const html = extractHtml(decodeText(document.bytes, document.charset), finalUrl);
  assertEnoughText(html.text);
  return {
    source: "web",
    text: html.text,
    sourceUrl: url,
    sourceTitle: html.title,
    siteName: html.siteName ?? hostOf(finalUrl),
    lang: html.lang,
    imageUrl: html.imageUrl,
  };
}

export async function extractFromWebpage(input: {
  url: string; title?: string | null; content?: string | null; siteName?: string | null; lang?: string | null;
}): Promise<ExtractedContent> {
  const content = normalizeWhitespace(input.content ?? "");
  if (!content) {
    const fetched = await extractFromUrl(input.url);
    return {
      ...fetched,
      sourceTitle: input.title?.trim() || fetched.sourceTitle,
      siteName: input.siteName?.trim() || fetched.siteName,
      lang: input.lang?.trim() || fetched.lang,
    };
  }
  assertEnoughText(content);
  return {
    source: "web",
    text: content,
    sourceUrl: input.url,
    sourceTitle: input.title?.trim() || null,
    siteName: input.siteName?.trim() || hostOf(input.url),
    lang: input.lang?.trim() || null,
    imageUrl: null,
  };
}

export function extractFromText(input: { text: string; title?: string | null }): ExtractedContent {
  const text = normalizeWhitespace(input.text);
  assertEnoughText(text);
  return { source: "text", text, sourceUrl: null, sourceTitle: input.title?.trim() || null, siteName: null, lang: null, imageUrl: null };
}

export function truncateForModel(text: string, limit = LLM_TEXT_LIMIT): string {
  if (text.length <= limit) return text;
  return `${text.slice(0, limit)}\n\n[… truncated]`;
}
