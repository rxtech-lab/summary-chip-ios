/**
 * Runtime font loading for the OG renderer.
 *
 * Google Fonts' CSS API subsets a family to exactly the glyphs in `text=`, so even a CJK face
 * costs a few KB per image. Requests without a modern browser UA get TrueType, which satori can
 * read (it cannot read woff2). Any failure returns an empty list, which makes `next/og` fall back
 * to its bundled Latin font.
 */

export interface OgFont {
  name: string;
  data: ArrayBuffer;
  weight: 400 | 700;
  style: "normal";
}

const cache = new Map<string, Promise<ArrayBuffer | null>>();
const MAX_CACHE = 200;

export function fontFamilyFor(text: string, language: string): string {
  if (/[぀-ヿ]/.test(text) || language.startsWith("ja")) return "Noto Sans JP";
  if (/[가-힯ᄀ-ᇿ]/.test(text) || language.startsWith("ko")) return "Noto Sans KR";
  if (/[㐀-鿿豈-﫿]/.test(text)) {
    return /^zh-(hant|tw|hk|mo)/i.test(language) ? "Noto Sans TC" : "Noto Sans SC";
  }
  return "Noto Sans";
}

async function fetchFont(family: string, weight: number, text: string): Promise<ArrayBuffer | null> {
  const url = `https://fonts.googleapis.com/css2?family=${encodeURIComponent(family).replace(/%20/g, "+")}:wght@${weight}&text=${encodeURIComponent(text)}`;
  try {
    const css = await (await fetch(url, { signal: AbortSignal.timeout(5000) })).text();
    const source = /src:\s*url\(([^)]+)\)\s*format\(['"](opentype|truetype)['"]\)/.exec(css)?.[1];
    if (!source) return null;
    const response = await fetch(source.replace(/['"]/g, ""), { signal: AbortSignal.timeout(8000) });
    if (!response.ok) return null;
    return await response.arrayBuffer();
  } catch {
    return null;
  }
}

function loadFont(family: string, weight: number, text: string): Promise<ArrayBuffer | null> {
  const key = `${family}|${weight}|${text}`;
  let pending = cache.get(key);
  if (!pending) {
    if (cache.size >= MAX_CACHE) cache.delete(cache.keys().next().value as string);
    pending = fetchFont(family, weight, text);
    cache.set(key, pending);
    pending.then((value) => { if (!value) cache.delete(key); }, () => cache.delete(key));
  }
  return pending;
}

export function remoteFontsEnabled(): boolean {
  if (process.env.SUMMARY_OG_REMOTE_ASSETS === "false") return false;
  return process.env.NODE_ENV !== "test" || process.env.SUMMARY_OG_REMOTE_ASSETS === "true";
}

export async function loadOgFonts(text: string, language: string): Promise<OgFont[]> {
  if (!remoteFontsEnabled()) return [];
  const glyphs = [...new Set(Array.from(text.replace(/\s+/g, " ")))].join("") + " ·…";
  const family = fontFamilyFor(text, language);
  const [regular, bold] = await Promise.all([loadFont(family, 400, glyphs), loadFont(family, 700, glyphs)]);
  const fonts: OgFont[] = [];
  if (regular) fonts.push({ name: family, data: regular, weight: 400, style: "normal" });
  if (bold) fonts.push({ name: family, data: bold, weight: 700, style: "normal" });
  return fonts;
}
