import { hashString } from "@/lib/ai/summary-schema";

/** Small deterministic PRNG (mulberry32) so the same seed always yields the same artwork. */
function random(seed: number): () => number {
  let state = seed || 1;
  return () => {
    state |= 0;
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * Deterministic geometric decoration used when the model's SVG is missing or rejected: layered
 * material-style "paper" shapes with soft elevation shadows, fine line work and a dot grid, all
 * kept to the right half where no text is drawn.
 */
export function fallbackSvg(seed: string, colors: string[], mode: "light" | "dark" = "dark"): string {
  const next = random(hashString(seed));
  const between = (min: number, max: number) => Math.round(min + next() * (max - min));
  const palette = colors.length ? [...colors] : ["#1d4ed8", "#38bdf8", "#e0f2fe"];
  // Seeded shuffle so neighbouring shapes take different palette entries.
  for (let index = palette.length - 1; index > 0; index -= 1) {
    const swap = Math.floor(next() * (index + 1));
    [palette[index], palette[swap]] = [palette[swap], palette[index]];
  }
  const color = (index: number) => palette[index % palette.length];
  const ink = mode === "dark" ? "#ffffff" : "#0f172a";
  const shapes: string[] = [];

  // Dot grid texture.
  const gridX = between(760, 820);
  const gridY = between(60, 110);
  for (let row = 0; row < 6; row += 1) {
    for (let column = 0; column < 6; column += 1) {
      shapes.push(`<circle cx="${gridX + column * 26}" cy="${gridY + row * 26}" r="2.5" fill="${ink}" opacity="0.28"/>`);
    }
  }

  // Concentric line rings behind the main disc.
  const ringX = between(940, 1010);
  const ringY = between(250, 330);
  for (let ring = 0; ring < 4; ring += 1) {
    shapes.push(`<circle cx="${ringX}" cy="${ringY}" r="${250 + ring * 34}" fill="none" stroke="${ink}" stroke-width="1.5" opacity="${(0.22 - ring * 0.04).toFixed(2)}"/>`);
  }

  // Elevated sheets: a shadow copy (blurred, offset downward) under each flat shape.
  const sheet = (shape: string, depth: number) => {
    shapes.push(`<g filter="url(#elevation)" opacity="${(0.18 + depth * 0.04).toFixed(2)}" transform="translate(0 ${6 + depth * 6})">${shape.replace(/fill="[^"]*"/, `fill="#020617"`)}</g>`);
    shapes.push(shape);
  };
  const discR = between(170, 210);
  sheet(`<circle cx="${ringX}" cy="${ringY}" r="${discR}" fill="${color(0)}"/>`, 3);
  const cardW = between(220, 280);
  const cardH = between(140, 170);
  const cardX = ringX - between(170, 220);
  const cardY = ringY + between(20, 60);
  const tilt = between(-14, 14);
  sheet(`<rect x="${cardX}" y="${cardY}" width="${cardW}" height="${cardH}" rx="28" fill="${color(1)}" transform="rotate(${tilt} ${cardX + cardW / 2} ${cardY + cardH / 2})"/>`, 2);
  // Half-disc anchored to the right edge.
  const halfY = between(420, 540);
  const halfR = between(90, 130);
  sheet(`<path d="M1200 ${halfY - halfR} A ${halfR} ${halfR} 0 0 0 1200 ${halfY + halfR} Z" fill="${color(2)}"/>`, 1);
  // Quarter-circle in the top-right corner.
  const quarterR = between(110, 150);
  sheet(`<path d="M1200 0 L${1200 - quarterR} 0 A ${quarterR} ${quarterR} 0 0 0 1200 ${quarterR} Z" fill="${color(3)}"/>`, 1);

  // Diagonal hairlines crossing the disc.
  const lineStart = between(700, 780);
  for (let line = 0; line < 5; line += 1) {
    const x = lineStart + line * 22;
    shapes.push(`<line x1="${x}" y1="630" x2="${x + 330}" y2="300" stroke="${ink}" stroke-width="2" stroke-linecap="round" opacity="0.3"/>`);
  }

  // Small accents: an outlined ring and a plus mark.
  shapes.push(`<circle cx="${between(1060, 1130)}" cy="${between(470, 560)}" r="18" fill="none" stroke="${ink}" stroke-width="3" opacity="0.6"/>`);
  const plusX = between(720, 780);
  const plusY = between(430, 520);
  shapes.push(`<path d="M${plusX - 14} ${plusY} H${plusX + 14} M${plusX} ${plusY - 14} V${plusY + 14}" stroke="${ink}" stroke-width="3" stroke-linecap="round" opacity="0.6"/>`);

  const defs = `<defs><filter id="elevation" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="14"/></filter></defs>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 630" width="1200" height="630">${defs}${shapes.join("")}</svg>`;
}
