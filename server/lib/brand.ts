/**
 * The Chippy app icon, flattened from the layers in `Chippy.icon` (bottom to
 * top: back card, front card, summary lines, sparkle) so the website, favicon
 * and social images all share one source.
 */

export const BRAND = {
  background: "#EEE5FC",
  coral: "#F57F6B",
  coralLight: "#FFB29B",
  ink: "#17213F",
} as const;

const DEFINITIONS = `
  <defs>
    <linearGradient id="chippy-lavender" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#EEE8FF"/><stop offset="1" stop-color="#B9A6E6"/></linearGradient>
    <linearGradient id="chippy-coral" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#FFB29B"/><stop offset="0.55" stop-color="#FF987F"/><stop offset="1" stop-color="#F57F6B"/></linearGradient>
    <linearGradient id="chippy-ink" x1="0" y1="0" x2="0" y2="1"><stop stop-color="#303B60"/><stop offset="1" stop-color="#17213F"/></linearGradient>
    <linearGradient id="chippy-sparkle" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#FAF5FF"/><stop offset="1" stop-color="#C5B5EC"/></linearGradient>
  </defs>`;

const BACK_CARD = `<rect x="226" y="319" width="468" height="462" rx="76" fill="url(#chippy-lavender)" transform="rotate(-5 460 550)"/>`;
const FRONT_CARD = `
  <rect x="294" y="229" width="500" height="510" rx="82" fill="url(#chippy-coral)" transform="rotate(6 544 484)"/>
  <g fill="url(#chippy-ink)" transform="rotate(6 544 484)">
    <rect x="366" y="435" width="306" height="52" rx="26"/>
    <rect x="366" y="516" width="248" height="52" rx="26"/>
    <rect x="366" y="597" width="178" height="52" rx="26"/>
  </g>`;
const SPARKLE = `<path d="M695 303 C701 303 703 313 710 331 C716 347 727 356 744 363 C763 371 773 374 773 381 C773 388 762 391 744 399 C727 406 716 417 709 434 C702 453 699 463 692 463 C685 463 682 452 675 434 C668 417 657 407 640 400 C621 392 611 389 611 382 C611 375 622 372 640 364 C657 357 668 346 675 329 C683 311 686 303 695 303 Z" fill="url(#chippy-sparkle)" transform="translate(-22 0) scale(1 0.82) translate(0 74)"/>`;
const LAYERS = DEFINITIONS + BACK_CARD + FRONT_CARD + SPARKLE;

/** Individually animated card layers; the final arrangement is the Chippy icon. */
export function chippyAssemblySvg(): string {
  const artwork = `${DEFINITIONS}<g class="intro-back-card">${BACK_CARD}</g><g class="intro-front-card">${FRONT_CARD}</g><g class="intro-sparkle">${SPARKLE}</g>`
    .replaceAll("chippy-", "chippy-intro-");
  return `<svg xmlns="http://www.w3.org/2000/svg" width="1408" height="1152" viewBox="-192 -64 1408 1152" fill="none">${artwork}</svg>`;
}

/** `rounded` gives the squircle-ish tile used for favicons; iOS masks its own corners, so the apple icon is full-bleed. */
export function chippyIconSvg({ rounded = true }: { rounded?: boolean } = {}): string {
  const radius = rounded ? 230 : 0;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><rect width="1024" height="1024" rx="${radius}" fill="${BRAND.background}"/>${LAYERS}</svg>`;
}

export function chippyIconDataUri(options?: { rounded?: boolean }): string {
  return `data:image/svg+xml;base64,${Buffer.from(chippyIconSvg(options)).toString("base64")}`;
}
