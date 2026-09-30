import { describe, expect, it } from "vitest";
import { fallbackSvg } from "@/lib/og/fallback-svg";
import { sanitizeSvg } from "@/lib/og/sanitize-svg";

describe("sanitizeSvg", () => {
  it("keeps allowed shapes and gradients and normalises the root", () => {
    const out = sanitizeSvg(`Here you go:\n\`\`\`svg\n<svg viewBox="0 0 1200 630" width="10"><defs><linearGradient id="g1"><stop offset="0" stop-color="#fff"/></linearGradient></defs><circle cx="10" cy="10" r="5" fill="url(#g1)"/></svg>\n\`\`\``);
    expect(out).toContain('<circle cx="10" cy="10" r="5" fill="url(#g1)"/>');
    expect(out).toContain("<linearGradient id=\"g1\">");
    expect(out).toMatch(/^<svg xmlns="http:\/\/www.w3.org\/2000\/svg" viewBox="0 0 1200 630" width="1200" height="630"/);
  });

  it("strips scripts, foreignObject, style, images, handlers and external references", () => {
    const out = sanitizeSvg(`<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)">
      <script>alert(1)</script>
      <foreignObject><div>hi</div></foreignObject>
      <style>circle{fill:url(https://evil.example/x)}</style>
      <image href="https://evil.example/a.png"/>
      <use href="#a"/>
      <a href="javascript:alert(1)"><rect width="10" height="10"/></a>
      <rect x="1" y="1" width="5" height="5" onclick="x()" fill="url(https://evil.example/p)" style="fill:red" stroke="javascript:alert(1)"/>
      <path d="M0 0L10 10" fill="#123456"/>
    </svg>`)!;
    expect(out).not.toMatch(/script|foreignObject|style|image|<use|<a |onload|onclick|evil|javascript/i);
    expect(out).toContain('<rect x="1" y="1" width="5" height="5"/>');
    expect(out).toContain('<path d="M0 0L10 10" fill="#123456"/>');
  });

  it("escapes attribute values and rejects unusable input", () => {
    const out = sanitizeSvg(`<svg><rect width="1" height="1" fill="&quot;/&gt;&lt;script&gt;"/></svg>`);
    expect(out ?? "").not.toContain("<script");
    expect(sanitizeSvg("no svg here")).toBeNull();
    expect(sanitizeSvg("<svg><script>alert(1)</script></svg>")).toBeNull();
    expect(sanitizeSvg(`<svg>${"<g>".repeat(40)}<rect width="1" height="1"/>${"</g>".repeat(40)}</svg>`)).toBeNull();
    expect(sanitizeSvg("<svg>" + "x".repeat(70_000) + "</svg>")).toBeNull();
  });

  it("generates a deterministic fallback that survives sanitising", () => {
    const a = fallbackSvg("seed", ["#111111", "#222222", "#333333", "#444444"]);
    expect(fallbackSvg("seed", ["#111111", "#222222", "#333333", "#444444"])).toBe(a);
    expect(sanitizeSvg(a)).not.toBeNull();
  });
});
