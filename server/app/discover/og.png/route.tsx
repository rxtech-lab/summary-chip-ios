import { ImageResponse } from "next/og";
import { BRAND, chippyIconDataUri } from "@/lib/brand";
import { getDatabase } from "@/lib/db/client";
import { loadOgFonts } from "@/lib/og/fonts";
import { listedAuthorName } from "@/lib/services/marketplace";

export const runtime = "nodejs";

const COVERS = [
  `linear-gradient(135deg, ${BRAND.coralLight}, ${BRAND.coral})`,
  "linear-gradient(135deg, #EEE8FF, #B9A6E6)",
  "linear-gradient(135deg, #303B60, #17213F)",
  "linear-gradient(135deg, #FFE1D8, #FFB29B)",
  "linear-gradient(135deg, #C5B5EC, #8B7CBC)",
];

/** A feed card with its text drawn as bars, so the art needs no real content. */
function FeedCard({ cover, top, left }: { cover: string; top: number; left: number }) {
  return (
    <div style={{ position: "absolute", top, left, width: 232, display: "flex", flexDirection: "column", borderRadius: 28, overflow: "hidden", backgroundColor: "#ffffff", boxShadow: "0 24px 48px rgba(23, 33, 63, 0.16)" }}>
      <div style={{ display: "flex", height: 128, backgroundImage: cover }} />
      <div style={{ display: "flex", flexDirection: "column", gap: 12, padding: 22 }}>
        <div style={{ display: "flex", width: 64, height: 12, borderRadius: 6, backgroundColor: BRAND.coral }} />
        <div style={{ display: "flex", width: "100%", height: 12, borderRadius: 6, backgroundColor: "#E5E7EB" }} />
        <div style={{ display: "flex", width: "72%", height: 12, borderRadius: 6, backgroundColor: "#E5E7EB" }} />
      </div>
    </div>
  );
}

/** The Discover link preview, or an author's when `?author=` names someone with listed content. */
export async function GET(request: Request) {
  const author = new URL(request.url).searchParams.get("author");
  const name = author ? await listedAuthorName(getDatabase(), author) : null;
  const shortName = name && Array.from(name).length > 40 ? `${Array.from(name).slice(0, 39).join("")}…` : name;
  const lines = shortName ? [shortName] : ["Discover something", "worth keeping."];
  const subtitle = shortName ? "Summaries, podcasts and more, published on Chippy." : "Summaries, podcasts and more, from the Chippy community.";
  const fonts = await loadOgFonts(`Chippy Discover ${lines.join(" ")} ${subtitle}`, "en");
  const headlineLength = Array.from(lines[0]).length;
  return new ImageResponse(
    (
      <div style={{ width: "100%", height: "100%", display: "flex", position: "relative", overflow: "hidden", backgroundColor: "#FFF8F5", color: BRAND.ink, ...(fonts[0] ? { fontFamily: fonts[0].name } : {}) }}>
        <div style={{ position: "absolute", right: -180, top: -140, width: 760, height: 760, borderRadius: 380, backgroundColor: "#FFE1D8" }} />
        <FeedCard cover={COVERS[0]} top={-70} left={690} />
        <FeedCard cover={COVERS[1]} top={224} left={690} />
        <FeedCard cover={COVERS[2]} top={518} left={690} />
        <FeedCard cover={COVERS[3]} top={40} left={950} />
        <FeedCard cover={COVERS[4]} top={334} left={950} />
        <div style={{ display: "flex", flexDirection: "column", justifyContent: "center", padding: "0 0 0 72px", width: 640 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 16, fontSize: 32 }}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={chippyIconDataUri()} width={64} height={64} alt="" />
            <span style={{ fontWeight: 700 }}>Chippy</span>
            <span style={{ color: "#475069" }}>·</span>
            <span style={{ color: BRAND.coral, fontWeight: 700 }}>Discover</span>
          </div>
          <div style={{ display: "flex", flexDirection: "column", marginTop: 40, fontSize: !shortName ? 58 : headlineLength <= 14 ? 84 : headlineLength <= 26 ? 64 : 52, fontWeight: 700, lineHeight: 1.08, letterSpacing: -1.5 }}>
            {lines.map((line, index) => <span key={line} style={index === 1 ? { color: BRAND.coral } : {}}>{line}</span>)}
          </div>
          <div style={{ display: "flex", marginTop: 28, fontSize: 28, lineHeight: 1.4, color: "#475069" }}>{subtitle}</div>
        </div>
      </div>
    ),
    { width: 1200, height: 630, ...(fonts.length ? { fonts } : {}), headers: { "Cache-Control": "public, max-age=3600, s-maxage=86400" } },
  );
}
