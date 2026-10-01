import type { AiProvider } from "./provider";

/**
 * http(s) URLs in free text. Stops at whitespace, CJK punctuation, fullwidth forms and ideographs,
 * since share sheets glue links straight onto Chinese/Japanese text ("…笔记https://xhslink.cn/o/1RV，").
 */
const URL_PATTERN = /https?:\/\/[^\s<>"'`　-〿㐀-鿿＀-￯]+/gi;
const TRAILING_PUNCTUATION = /[.,;:!?)\]}'"]+$/;

export function findUrls(text: string): string[] {
  const urls: string[] = [];
  for (const match of text.match(URL_PATTERN) ?? []) {
    const candidate = match.replace(TRAILING_PUNCTUATION, "");
    try {
      const url = new URL(candidate);
      if ((url.protocol === "http:" || url.protocol === "https:") && url.hostname.includes(".")) urls.push(candidate);
    } catch {
      // Not a parseable URL; leave it as text.
    }
  }
  return [...new Set(urls)];
}

/**
 * Decides whether text pasted or shared by the user should be summarised as-is or is really a
 * link to open (a share snippet such as "teaser… https://… copy this and open the app"). Text
 * without a URL never reaches the evaluation model; a bare URL is followed without asking.
 *
 * Returns the URL to fetch, or null to summarise the text itself.
 */
export async function linkToFollow(ai: AiProvider, text: string): Promise<string | null> {
  const urls = findUrls(text);
  const [first] = urls;
  if (!first) return null;
  if (urls.length === 1 && text.trim().replace(TRAILING_PUNCTUATION, "") === first) return first;
  return (await ai.isSharedLink(text)) ? first : null;
}
