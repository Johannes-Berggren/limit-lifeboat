#!/usr/bin/env node

/**
 * Builds dist/llms-full.txt from the rendered HTML.
 *
 * Reading the built output rather than the source means the full-text file always matches
 * what a crawler actually sees, and no page can be added without appearing here. Run as a
 * postbuild step so it covers Vercel deploys, not just CI.
 */

import { readdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const distRoot = path.resolve(process.argv[2] ?? "dist");
const siteOrigin = "https://limitlifeboat.com";

// Order matters: the home page first, then guides, then the rest. Anything not listed
// still gets appended, so a new route can never silently vanish from the output.
const preferredOrder = [
  "/",
  "/guides",
  "/download",
  "/changelog",
  "/support",
  "/privacy",
];

async function htmlFilesBelow(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(
    entries.map(async (entry) => {
      const entryPath = path.join(directory, entry.name);
      if (entry.isDirectory()) return htmlFilesBelow(entryPath);
      return entry.name.endsWith(".html") ? [entryPath] : [];
    }),
  );
  return nested.flat();
}

function publicPathFor(htmlPath) {
  const relative = path.relative(distRoot, htmlPath).split(path.sep).join("/");
  if (relative === "index.html") return "/";
  if (relative.endsWith("/index.html")) return `/${relative.slice(0, -"/index.html".length)}`;
  return `/${relative.replace(/\.html$/, "")}`;
}

function decodeEntities(value) {
  const named = {
    amp: "&",
    lt: "<",
    gt: ">",
    quot: '"',
    apos: "'",
    nbsp: " ",
    hellip: "…",
    mdash: "—",
    ndash: "–",
    rsquo: "’",
    lsquo: "‘",
    ldquo: "“",
    rdquo: "”",
  };
  return value
    .replace(/&#(\d+);/g, (_, code) => String.fromCodePoint(Number(code)))
    .replace(/&#x([0-9a-f]+);/gi, (_, code) => String.fromCodePoint(Number.parseInt(code, 16)))
    .replace(/&([a-z]+);/gi, (match, name) => named[name.toLowerCase()] ?? match);
}

/** Strips tags from a fragment and collapses whitespace. */
function textOf(fragment) {
  return decodeEntities(fragment.replace(/<[^>]+>/g, " "))
    .replace(/\s+/g, " ")
    .trim();
}

function extractMain(html) {
  const match = html.match(/<main[^>]*id="main-content"[^>]*>([\s\S]*?)<\/main>/i);
  return match ? match[1] : "";
}

/** Renders the main content as plain-ish markdown: headings, paragraphs, and list items. */
function contentToText(main) {
  const withoutNoise = main
    // Decorative and navigational chrome carries no meaning for a reader.
    .replace(/<aside\b[^>]*class="[^"]*article-nav[^"]*"[\s\S]*?<\/aside>/gi, "")
    .replace(/<nav\b[\s\S]*?<\/nav>/gi, "")
    .replace(/<figure\b[\s\S]*?<\/figure>/gi, "")
    .replace(/<svg\b[\s\S]*?<\/svg>/gi, "")
    .replace(/<script\b[\s\S]*?<\/script>/gi, "")
    .replace(/<style\b[\s\S]*?<\/style>/gi, "");

  const blocks = [];
  const blockPattern =
    /<(h1|h2|h3|h4|p|li|pre|th|td|summary)\b[^>]*>([\s\S]*?)<\/\1>/gi;

  let match;
  while ((match = blockPattern.exec(withoutNoise)) !== null) {
    const tag = match[1].toLowerCase();
    const text = textOf(match[2]);
    if (!text) continue;

    if (tag === "h1") blocks.push(`# ${text}`);
    else if (tag === "h2") blocks.push(`## ${text}`);
    else if (tag === "h3" || tag === "summary") blocks.push(`### ${text}`);
    else if (tag === "h4") blocks.push(`#### ${text}`);
    else if (tag === "li") blocks.push(`- ${text}`);
    else if (tag === "pre") blocks.push("```\n" + text + "\n```");
    else if (tag === "th" || tag === "td") blocks.push(`| ${text}`);
    else blocks.push(text);
  }

  // Collapse the run of single table cells into readable rows.
  const merged = [];
  for (const block of blocks) {
    const previous = merged[merged.length - 1];
    if (block.startsWith("| ") && previous?.startsWith("| ")) {
      merged[merged.length - 1] = `${previous} ${block.slice(2)}`;
    } else {
      merged.push(block);
    }
  }

  return merged.join("\n\n");
}

function titleOf(html) {
  const match = html.match(/<title>([\s\S]*?)<\/title>/i);
  return match ? textOf(match[1]) : "";
}

function descriptionOf(html) {
  const match = html.match(/<meta\s+name="description"\s+content="([^"]*)"/i);
  return match ? decodeEntities(match[1]) : "";
}

function isNoindex(html) {
  return /<meta\s+name="robots"\s+content="[^"]*noindex/i.test(html);
}

const htmlFiles = await htmlFilesBelow(distRoot);
const pages = [];

for (const htmlFile of htmlFiles) {
  const html = await readFile(htmlFile, "utf8");
  if (isNoindex(html)) continue;

  const pagePath = publicPathFor(htmlFile);
  const body = contentToText(extractMain(html));
  if (!body) continue;

  pages.push({
    path: pagePath,
    title: titleOf(html),
    description: descriptionOf(html),
    body,
  });
}

pages.sort((a, b) => {
  const rank = (entry) => {
    const explicit = preferredOrder.indexOf(entry.path);
    if (explicit !== -1) return explicit;
    return preferredOrder.length + (entry.path.startsWith("/guides/") ? 0 : 1);
  };
  const difference = rank(a) - rank(b);
  return difference !== 0 ? difference : a.path.localeCompare(b.path);
});

const header = `# Limit Lifeboat — full site text

Every indexable page on ${siteOrigin}, as plain text, generated from the built HTML.
The canonical HTML version of each page is linked above its content.

`;

const sections = pages.map((page) => {
  const url = `${siteOrigin}${page.path === "/" ? "" : page.path}`;
  const frontMatter = [`URL: ${url}`, `Title: ${page.title}`];
  if (page.description) frontMatter.push(`Description: ${page.description}`);
  return `---\n\n${frontMatter.join("\n")}\n\n${page.body}`;
});

const output = `${header}${sections.join("\n\n")}\n`;
const outputPath = path.join(distRoot, "llms-full.txt");
await writeFile(outputPath, output, "utf8");

const kilobytes = (Buffer.byteLength(output, "utf8") / 1024).toFixed(1);
console.log(`Wrote ${path.relative(process.cwd(), outputPath)} (${pages.length} pages, ${kilobytes} kB).`);

if (pages.length === 0) {
  console.error("No indexable pages found — llms-full.txt would be empty.");
  process.exitCode = 1;
}
