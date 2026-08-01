import type { APIRoute, GetStaticPaths } from "astro";
import sharp from "sharp";
import { product } from "../../config";
import { guides, ogSlugFor, staticPages } from "../../data/pages";

/**
 * Build-time Open Graph card generator.
 *
 * Every page shared the same static /og-card.png, which makes a link to a guide look
 * identical to a link to the home page. This renders the page's own title onto the same
 * visual template with sharp, which is already a dependency for image optimisation.
 *
 * Fonts: librsvg resolves through fontconfig, so the stack ends in a generic family that
 * exists on both macOS and the Linux CI image. The card degrades to a different sans-serif
 * rather than failing if a preferred face is missing.
 */

const FONT_STACK = "-apple-system, BlinkMacSystemFont, Helvetica Neue, Helvetica, Arial, sans-serif";
const CARD_WIDTH = 1200;
const CARD_HEIGHT = 630;
const TEXT_LEFT = 92;
const TEXT_RIGHT_MARGIN = 92;

interface CardSpec {
  slug: string;
  kicker: string;
  title: string;
  footer: string;
}

function escapeXml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

/**
 * Greedy wrap using an approximate advance width. Exact metrics are not available without
 * loading the font, and an approximation is fine because the layout has generous margins.
 */
function wrap(text: string, fontSize: number, maxWidth: number): string[] {
  const averageAdvance = fontSize * 0.52;
  const maxChars = Math.max(12, Math.floor(maxWidth / averageAdvance));
  const lines: string[] = [];
  let current = "";

  for (const word of text.split(/\s+/)) {
    const candidate = current ? `${current} ${word}` : word;
    if (candidate.length <= maxChars) {
      current = candidate;
    } else {
      if (current) lines.push(current);
      current = word;
    }
  }
  if (current) lines.push(current);
  return lines;
}

function renderSvg({ kicker, title, footer }: CardSpec): string {
  const maxWidth = CARD_WIDTH - TEXT_LEFT - TEXT_RIGHT_MARGIN;

  // Shrink the type until the title fits in three lines rather than overflowing the card.
  let fontSize = 61;
  let lines = wrap(title, fontSize, maxWidth);
  while (lines.length > 3 && fontSize > 38) {
    fontSize -= 5;
    lines = wrap(title, fontSize, maxWidth);
  }
  lines = lines.slice(0, 3);

  const lineHeight = Math.round(fontSize * 1.24);
  // Centre the title block in the band between the kicker and the footer, so one-line and
  // three-line cards are both balanced rather than one hugging the footer.
  const titleBaseline = Math.round(
    390 - ((lines.length - 1) * lineHeight) / 2 + fontSize * 0.35,
  );

  const titleMarkup = lines
    .map(
      (line, index) =>
        `<text x="${TEXT_LEFT}" y="${titleBaseline + index * lineHeight}" fill="${
          index === lines.length - 1 ? "#5233B5" : "#0A0916"
        }" font-family="${FONT_STACK}" font-size="${fontSize}" font-weight="750" letter-spacing="-2.5">${escapeXml(line)}</text>`,
    )
    .join("");

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${CARD_WIDTH}" height="${CARD_HEIGHT}" viewBox="0 0 ${CARD_WIDTH} ${CARD_HEIGHT}">
  <defs>
    <linearGradient id="bg" x1="80" y1="30" x2="1130" y2="610" gradientUnits="userSpaceOnUse">
      <stop stop-color="#FBFAFF"/>
      <stop offset="1" stop-color="#F2FAFD"/>
    </linearGradient>
    <linearGradient id="brand" x1="80" y1="75" x2="265" y2="265" gradientUnits="userSpaceOnUse">
      <stop stop-color="#5233B5"/>
      <stop offset="1" stop-color="#1F8CC2"/>
    </linearGradient>
    <radialGradient id="violet" cx="0" cy="0" r="1" gradientTransform="translate(165 185) rotate(45) scale(450)">
      <stop stop-color="#7658DA" stop-opacity=".26"/>
      <stop offset="1" stop-color="#7658DA" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="cyan" cx="0" cy="0" r="1" gradientTransform="translate(1075 510) rotate(-135) scale(470)">
      <stop stop-color="#28A2CF" stop-opacity=".24"/>
      <stop offset="1" stop-color="#28A2CF" stop-opacity="0"/>
    </radialGradient>
    <filter id="shadow" x="-30" y="-30" width="300" height="300" filterUnits="userSpaceOnUse">
      <feDropShadow dx="0" dy="14" stdDeviation="16" flood-color="#312679" flood-opacity=".2"/>
    </filter>
    <pattern id="grid" width="56" height="56" patternUnits="userSpaceOnUse">
      <path d="M56 0H0v56" fill="none" stroke="#302663" stroke-opacity=".035"/>
    </pattern>
  </defs>
  <rect width="${CARD_WIDTH}" height="${CARD_HEIGHT}" fill="url(#bg)"/>
  <rect width="${CARD_WIDTH}" height="${CARD_HEIGHT}" fill="url(#violet)"/>
  <rect width="${CARD_WIDTH}" height="${CARD_HEIGHT}" fill="url(#cyan)"/>
  <rect width="${CARD_WIDTH}" height="${CARD_HEIGHT}" fill="url(#grid)"/>
  <g transform="translate(92 88) scale(0.72)" filter="url(#shadow)">
    <rect width="158" height="158" rx="45" fill="url(#brand)"/>
    <rect x="2" y="2" width="154" height="154" rx="43" fill="none" stroke="#fff" stroke-opacity=".4" stroke-width="3"/>
    <circle cx="79" cy="79" r="41" fill="none" stroke="#fff" stroke-width="18"/>
    <path d="m49 49 13 13m34 34 13 13m0-60L96 62M62 96l-13 13" stroke="#3677BE" stroke-width="18"/>
    <path d="M60 92a25 25 0 0 1 40-24M79 79l18-15" fill="none" stroke="#fff" stroke-width="8" stroke-linecap="round"/>
    <circle cx="79" cy="79" r="7" fill="#fff"/>
  </g>
  <text x="216" y="150" fill="#141423" font-family="${FONT_STACK}" font-size="32" font-weight="700" letter-spacing="-0.8">${escapeXml(product.name)}</text>
  <text x="${TEXT_LEFT}" y="262" fill="#5233B5" font-family="${FONT_STACK}" font-size="23" font-weight="650" letter-spacing="2">${escapeXml(kicker.toUpperCase())}</text>
  ${titleMarkup}
  <text x="${TEXT_LEFT + 3}" y="532" fill="#626277" font-family="${FONT_STACK}" font-size="25">${escapeXml(footer)}</text>
  <g transform="translate(902 91)">
    <rect width="207" height="48" rx="24" fill="#fff" fill-opacity=".72" stroke="#302663" stroke-opacity=".1"/>
    <circle cx="27" cy="24" r="5" fill="#18A14C"/>
    <text x="44" y="31" fill="#4F4E63" font-family="${FONT_STACK}" font-size="18" font-weight="600">Native for macOS</text>
  </g>
</svg>`;
}

const cards: CardSpec[] = [
  ...staticPages.map((page) => ({
    slug: ogSlugFor(page.path),
    kicker: page.kicker,
    title: page.path === "/" ? product.headline : page.title,
    footer:
      page.path === "/"
        ? "Verified restore. Rollback on failure. settings.json untouched."
        : page.summary,
  })),
  ...guides.map((guide) => ({
    slug: ogSlugFor(guide.path),
    kicker: guide.eyebrow,
    title: guide.title,
    footer: `limitlifeboat.com · ${guide.readingTime}`,
  })),
];

export const getStaticPaths: GetStaticPaths = () =>
  cards.map((card) => ({ params: { slug: card.slug }, props: { card } }));

export const GET: APIRoute = async ({ props }) => {
  const card = props.card as CardSpec;
  const png = await sharp(Buffer.from(renderSvg(card))).png({ compressionLevel: 9 }).toBuffer();

  return new Response(new Uint8Array(png), {
    headers: {
      "Content-Type": "image/png",
      "Cache-Control": "public, max-age=31536000, immutable",
    },
  });
};
