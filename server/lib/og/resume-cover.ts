import { hashString } from "@/lib/ai/summary-schema";
import { OG_HEIGHT, OG_WIDTH, renderArtPng } from "./render";

const palettes = [
  { colors: ["#f1f6fb", "#a8bacf"], accent: "#375d80", backing: "#c0d0e0" },
  { colors: ["#f2f7f4", "#a6c4bb"], accent: "#346b5d", backing: "#bfd4cc" },
  { colors: ["#fbf5ed", "#cbb59b"], accent: "#845940", backing: "#ddcbb6" },
];

/** Text-free artwork. The document motif stays within the center crop used by Library tiles. */
export function renderResumeCover(id: string): Promise<Uint8Array> {
  const { colors, accent, backing } = palettes[hashString(id) % palettes.length];
  const svg = `
    <svg xmlns="http://www.w3.org/2000/svg" width="${OG_WIDTH}" height="${OG_HEIGHT}" viewBox="0 0 ${OG_WIDTH} ${OG_HEIGHT}">
      <ellipse cx="610" cy="555" rx="218" ry="27" fill="${accent}" opacity=".13"/>
      <circle cx="602" cy="330" r="232" fill="#ffffff" opacity=".28"/>
      <circle cx="602" cy="330" r="252" fill="none" stroke="#ffffff" stroke-width="2" opacity=".55"/>
      <g transform="rotate(12 628 361)">
        <rect x="503" y="167" width="267" height="389" rx="18" fill="${accent}" opacity=".15"/>
        <rect x="498" y="157" width="267" height="389" rx="18" fill="${backing}" stroke="#ffffff" stroke-opacity=".65" stroke-width="2"/>
      </g>
      <g transform="rotate(-7 580 342)">
        <rect x="454" y="148" width="264" height="387" rx="18" fill="${accent}" opacity=".20"/>
        <rect x="448" y="136" width="264" height="387" rx="18" fill="#fffefa"/>
        <rect x="472" y="163" width="216" height="87" rx="10" fill="${backing}" opacity=".48"/>
        <circle cx="519" cy="207" r="24" fill="${accent}"/>
        <circle cx="519" cy="201" r="7" fill="#fffefa"/>
        <path d="M506 218a13 11 0 0 1 26 0z" fill="#fffefa"/>
        <path d="M561 198h93m-93 17h66M475 278h211" stroke="${accent}" stroke-width="5" stroke-linecap="round"/>
        <path d="M475 309h68m-68 99h68" stroke="${accent}" stroke-width="7" stroke-linecap="round"/>
        <path d="M475 332h203m-203 19h171m-171 19h188m-188 61h203m-203 19h175m-175 19h124" stroke="${backing}" stroke-width="5" stroke-linecap="round"/>
      </g>
    </svg>`;
  return renderArtPng({ colors, svg });
}
