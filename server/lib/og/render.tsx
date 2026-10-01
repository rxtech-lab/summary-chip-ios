import { ImageResponse } from "next/og";
import { luminance } from "@/lib/ai/summary-schema";
import { loadOgFonts } from "./fonts";

export const OG_WIDTH = 1200;
export const OG_HEIGHT = 630;

export interface OgCardInput {
  headline: string;
  category: string;
  siteLabel: string | null;
  colors: string[];
  mode: "light" | "dark";
  accent: string;
  language: string;
  /** Sanitised SVG markup drawn as decoration. */
  svg?: string | null;
  /** A 1200×630 PNG drawn full-bleed as the background (the illustration); takes precedence over `svg`. */
  image?: Uint8Array | null;
}

function dataUrl(bytes: Uint8Array | string, mediaType: string): string {
  return `data:${mediaType};base64,${Buffer.from(bytes).toString("base64")}`;
}

function headlineSize(text: string): number {
  const units = Array.from(text).reduce((total, char) => total + (/[ᄀ-￿]/.test(char) ? 1.8 : 1), 0);
  if (units <= 28) return 76;
  if (units <= 45) return 64;
  if (units <= 60) return 56;
  return 48;
}

/** Brand mark: an accent disc overlapping an outlined rounded square. */
function brandMark(accent: string, ink: string) {
  return (
    <div style={{ display: "flex", position: "relative", width: 32, height: 32 }}>
      <div style={{ display: "flex", position: "absolute", left: 10, top: 0, width: 22, height: 22, borderRadius: 6, border: `2.5px solid ${ink}` }} />
      <div style={{ display: "flex", position: "absolute", left: 0, top: 10, width: 22, height: 22, borderRadius: 11, backgroundColor: accent }} />
    </div>
  );
}

function backgroundGradient(colors: string[]): string {
  return `linear-gradient(135deg, ${colors.join(", ")})`;
}

function artwork(input: Pick<OgCardInput, "svg" | "image">) {
  const src = input.image ? dataUrl(input.image, "image/png") : input.svg ? dataUrl(input.svg, "image/svg+xml") : null;
  return src ? (
    // eslint-disable-next-line @next/next/no-img-element
    <img src={src} alt="" width={OG_WIDTH} height={OG_HEIGHT} style={{ position: "absolute", top: 0, left: 0 }} />
  ) : null;
}

function renderCard(input: OgCardInput, fontFamily: string | undefined) {
  const dark = input.mode === "dark";
  const textColor = dark ? "#ffffff" : "#0f172a";
  const mutedColor = dark ? "rgba(255,255,255,0.78)" : "rgba(15,23,42,0.72)";
  const hairline = dark ? "rgba(255,255,255,0.28)" : "rgba(15,23,42,0.18)";
  const accent = luminance(input.accent) > 0.45 === dark ? input.accent : textColor;
  const gradient = backgroundGradient(input.colors);
  const scrim = dark
    ? "linear-gradient(90deg, rgba(2,6,23,0.82) 0%, rgba(2,6,23,0.55) 55%, rgba(2,6,23,0) 100%)"
    : "linear-gradient(90deg, rgba(255,255,255,0.88) 0%, rgba(255,255,255,0.6) 55%, rgba(255,255,255,0) 100%)";
  return (
    <div style={{ display: "flex", position: "relative", width: "100%", height: "100%", backgroundImage: gradient, ...(fontFamily ? { fontFamily } : {}) }}>
      {artwork(input)}
      <div style={{ display: "flex", position: "absolute", top: 0, left: 0, width: OG_WIDTH, height: OG_HEIGHT, backgroundImage: scrim }} />
      <div style={{ display: "flex", flexDirection: "column", justifyContent: "space-between", position: "relative", width: 720, height: "100%", padding: "68px 72px 60px" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 18 }}>
          <div style={{ display: "flex", width: 44, height: 6, borderRadius: 3, backgroundColor: accent }} />
          <div style={{ display: "flex", color: textColor, fontSize: 24, fontWeight: 700, letterSpacing: 4 }}>
            {input.category.toLocaleUpperCase(input.language)}
          </div>
        </div>
        <div style={{ display: "flex", color: textColor, fontSize: headlineSize(input.headline), fontWeight: 700, lineHeight: 1.12, letterSpacing: -1 }}>
          {input.headline}
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 24 }}>
          <div style={{ display: "flex", width: "100%", height: 2, backgroundColor: hairline }} />
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", color: mutedColor, fontSize: 26 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
              {brandMark(accent, textColor)}
              <span style={{ color: textColor, fontWeight: 700 }}>Chippy</span>
            </div>
            {input.siteLabel ? <span>{input.siteLabel}</span> : null}
          </div>
        </div>
      </div>
    </div>
  );
}

async function toPng(element: React.ReactElement, fonts: Awaited<ReturnType<typeof loadOgFonts>>): Promise<Uint8Array> {
  const response = new ImageResponse(element, { width: OG_WIDTH, height: OG_HEIGHT, ...(fonts.length ? { fonts } : {}) });
  return new Uint8Array(await response.arrayBuffer());
}

/** Renders the 1200×630 card. Retries once with the plain card if satori fails. */
export async function renderOgPng(input: OgCardInput): Promise<Uint8Array> {
  const text = `${input.headline}${input.category.toLocaleUpperCase(input.language)}${input.siteLabel ?? ""}Chippy`;
  const fonts = await loadOgFonts(text, input.language);
  try {
    return await toPng(renderCard(input, fonts[0]?.name), fonts);
  } catch (error) {
    console.warn("[og] render failed; retrying with the plain card", error);
    return toPng(renderCard(input, undefined), []);
  }
}

/** The card's background (palette gradient + decorative SVG) with no text, scrim or brand mark. */
export async function renderArtPng(input: Pick<OgCardInput, "colors" | "svg">): Promise<Uint8Array> {
  return toPng(
    <div style={{ display: "flex", position: "relative", width: "100%", height: "100%", backgroundImage: backgroundGradient(input.colors) }}>
      {artwork(input)}
    </div>,
    [],
  );
}
