import { ImageResponse } from "next/og";
import { BRAND, chippyIconDataUri } from "@/lib/brand";

export const alt = "Chippy — Read less. Share more.";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

function Card({ rotate, top, left, muted }: { rotate: number; top: number; left: number; muted?: boolean }) {
  return (
    <div
      style={{
        position: "absolute",
        top,
        left,
        width: 300,
        display: "flex",
        flexDirection: "column",
        borderRadius: 36,
        overflow: "hidden",
        backgroundColor: "#ffffff",
        boxShadow: "0 30px 60px rgba(23, 33, 63, 0.18)",
        transform: `rotate(${rotate}deg)`,
      }}
    >
      <div
        style={{
          height: 158,
          display: "flex",
          backgroundImage: muted
            ? `linear-gradient(135deg, #FFE1D8, ${BRAND.coralLight})`
            : `linear-gradient(135deg, ${BRAND.coralLight}, ${BRAND.coral})`,
        }}
      />
      <div style={{ display: "flex", flexDirection: "column", gap: 14, padding: 26 }}>
        <div style={{ width: 90, height: 22, borderRadius: 11, backgroundColor: BRAND.coral }} />
        <div style={{ width: "100%", height: 14, borderRadius: 7, backgroundColor: "#E5E7EB" }} />
        <div style={{ width: "80%", height: 14, borderRadius: 7, backgroundColor: "#E5E7EB" }} />
        <div style={{ width: "55%", height: 14, borderRadius: 7, backgroundColor: "#E5E7EB" }} />
      </div>
    </div>
  );
}

export default function OpengraphImage() {
  return new ImageResponse(
    (
      <div style={{ width: "100%", height: "100%", display: "flex", position: "relative", backgroundColor: "#FFF8F5", color: BRAND.ink }}>
        <div
          style={{
            position: "absolute",
            right: -160,
            top: -120,
            width: 720,
            height: 720,
            borderRadius: 360,
            backgroundColor: "#FFE1D8",
          }}
        />
        <div style={{ display: "flex", flexDirection: "column", justifyContent: "center", padding: "0 80px", width: 700 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 20 }}>
            <img src={chippyIconDataUri()} width={84} height={84} alt="" />
            <span style={{ fontSize: 40, fontWeight: 700 }}>Chippy</span>
          </div>
          <div style={{ display: "flex", flexDirection: "column", marginTop: 44, fontSize: 84, fontWeight: 800, lineHeight: 1.05, letterSpacing: -2 }}>
            <span>Read less.</span>
            <span style={{ color: BRAND.coral }}>Share more.</span>
          </div>
          <div style={{ marginTop: 30, fontSize: 30, lineHeight: 1.4, color: "#475069" }}>
            Summarise any page, PDF or note into a card you can share.
          </div>
        </div>
        <Card rotate={-7} top={90} left={760} muted />
        <Card rotate={5} top={170} left={850} />
      </div>
    ),
    size,
  );
}
