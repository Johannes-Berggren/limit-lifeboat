#!/usr/bin/env node

/**
 * Structural SEO guard for the built site.
 *
 * Everything here is mechanical and objectively checkable — one h1, a canonical that
 * matches the file's own path, JSON-LD that parses and whose @id references resolve. It
 * makes no judgement about copy quality. The point is that the invariants set up during
 * the SEO work cannot silently regress when someone adds a page later.
 */

import { readdir, readFile, stat } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const distRoot = path.resolve(process.argv[2] ?? "apps/site/dist");
const origin = "https://limitlifeboat.com";

// Rendered <title> budget. Google truncates around 60 characters; 65 leaves a little room
// for the " — Limit Lifeboat" suffix on the pages that genuinely need a long title.
const TITLE_MAX = 65;
const DESCRIPTION_MIN = 110;
const DESCRIPTION_MAX = 165;

// Every schema.org @type the site is allowed to emit, checked against the real vocabulary.
// An invented type (schema.org has no PrivacyPolicy, for instance) is silently ignored by
// consumers, so it has to fail here instead. Extend deliberately, after confirming the
// type exists at https://schema.org/<Type>.
const ALLOWED_TYPES = new Set([
  "Answer",
  "BreadcrumbList",
  "CollectionPage",
  "CreativeWork",
  "FAQPage",
  "HowTo",
  "HowToStep",
  "ImageObject",
  "ItemList",
  "ListItem",
  "Offer",
  "Organization",
  "Person",
  "Question",
  "SoftwareApplication",
  "TechArticle",
  "WebPage",
  "WebSite",
]);

const failures = [];
const warnings = [];

function fail(file, message) {
  failures.push(`${file}: ${message}`);
}

function warn(file, message) {
  warnings.push(`${file}: ${message}`);
}

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
  const named = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };
  return value
    .replace(/&#(\d+);/g, (_, code) => String.fromCodePoint(Number(code)))
    .replace(/&#x([0-9a-f]+);/gi, (_, code) => String.fromCodePoint(Number.parseInt(code, 16)))
    .replace(/&([a-z]+);/gi, (match, name) => named[name.toLowerCase()] ?? match);
}

function metaContent(html, attribute, name) {
  const pattern = new RegExp(
    `<meta[^>]*\\b${attribute}=["']${name}["'][^>]*\\bcontent=["']([^"']*)["']`,
    "i",
  );
  const match = html.match(pattern);
  return match ? decodeEntities(match[1]) : null;
}

/**
 * Walks a parsed JSON-LD value collecting declared @ids, referenced @ids, and every
 * @type encountered.
 */
function collectIds(node, declared, referenced, typesSeen) {
  if (Array.isArray(node)) {
    for (const item of node) collectIds(item, declared, referenced, typesSeen);
    return;
  }
  if (!node || typeof node !== "object") return;

  const keys = Object.keys(node);
  if (typeof node["@id"] === "string") {
    // A lone {"@id": "..."} is a reference; an @id alongside other keys is a declaration.
    if (keys.length === 1) referenced.add(node["@id"]);
    else declared.add(node["@id"]);
  }
  for (const type of [].concat(node["@type"] ?? [])) {
    if (typeof type === "string") typesSeen.add(type);
  }
  for (const key of keys) {
    if (key !== "@id") collectIds(node[key], declared, referenced, typesSeen);
  }
}

const htmlFiles = (await htmlFilesBelow(distRoot)).sort();
if (htmlFiles.length === 0) {
  console.error(`No HTML found under ${distRoot}. Build the site first.`);
  process.exit(1);
}

const seenTitles = new Map();
const indexablePaths = [];

for (const htmlFile of htmlFiles) {
  const file = path.relative(distRoot, htmlFile);
  const html = await readFile(htmlFile, "utf8");
  const pagePath = publicPathFor(htmlFile);
  const robots = metaContent(html, "name", "robots") ?? "";
  const noindex = /noindex/i.test(robots);

  // --- headings -----------------------------------------------------------------
  const h1Count = (html.match(/<h1[\s>]/gi) ?? []).length;
  if (h1Count !== 1) fail(file, `expected exactly one <h1>, found ${h1Count}`);

  // --- title --------------------------------------------------------------------
  const titleMatch = html.match(/<title>([\s\S]*?)<\/title>/i);
  if (!titleMatch) {
    fail(file, "missing <title>");
  } else {
    const title = decodeEntities(titleMatch[1]).trim();
    if (title.length === 0) fail(file, "empty <title>");
    if (title.length > TITLE_MAX) {
      fail(file, `<title> is ${title.length} chars, over the ${TITLE_MAX} limit: "${title}"`);
    }
    if (!noindex) {
      const previous = seenTitles.get(title);
      if (previous) fail(file, `duplicate <title> with ${previous}: "${title}"`);
      else seenTitles.set(title, file);
    }
  }

  // --- description --------------------------------------------------------------
  const description = metaContent(html, "name", "description");
  if (!description) {
    fail(file, "missing meta description");
  } else if (description.length < DESCRIPTION_MIN || description.length > DESCRIPTION_MAX) {
    fail(
      file,
      `meta description is ${description.length} chars, outside ${DESCRIPTION_MIN}-${DESCRIPTION_MAX}`,
    );
  }

  // --- canonical ----------------------------------------------------------------
  const canonicalMatch = html.match(/<link[^>]*\brel=["']canonical["'][^>]*\bhref=["']([^"']+)["']/i);
  if (!canonicalMatch) {
    fail(file, "missing canonical link");
  } else {
    const canonical = canonicalMatch[1];
    const expected = pagePath === "/" ? `${origin}/` : `${origin}${pagePath}`;
    if (canonical !== expected) {
      fail(file, `canonical is "${canonical}", expected "${expected}"`);
    }
  }

  // --- social -------------------------------------------------------------------
  for (const [attribute, name] of [
    ["property", "og:title"],
    ["property", "og:description"],
    ["property", "og:image"],
    ["property", "og:url"],
    ["name", "twitter:card"],
    ["name", "twitter:image"],
  ]) {
    if (!metaContent(html, attribute, name)) fail(file, `missing ${name}`);
  }

  const ogImage = metaContent(html, "property", "og:image");
  if (ogImage && !ogImage.startsWith("https://")) {
    fail(file, `og:image must be an absolute URL, got "${ogImage}"`);
  }

  // --- structured data ----------------------------------------------------------
  const blocks = [
    ...html.matchAll(/<script[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi),
  ];
  if (!noindex && blocks.length === 0) fail(file, "no JSON-LD block");

  const declared = new Set();
  const referenced = new Set();
  const typesSeen = new Set();
  const questionNames = [];

  for (const [, raw] of blocks) {
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch (error) {
      fail(file, `JSON-LD does not parse: ${error.message}`);
      continue;
    }
    collectIds(parsed, declared, referenced, typesSeen);

    const graph = Array.isArray(parsed["@graph"]) ? parsed["@graph"] : [parsed];
    for (const node of graph) {
      if (node?.["@type"] === "FAQPage" && Array.isArray(node.mainEntity)) {
        for (const question of node.mainEntity) {
          if (typeof question?.name === "string") questionNames.push(question.name);
          if (!question?.acceptedAnswer?.text) {
            fail(file, `FAQ question "${question?.name ?? "?"}" has no acceptedAnswer text`);
          }
        }
      }
    }
  }

  for (const reference of referenced) {
    if (!declared.has(reference)) {
      fail(file, `JSON-LD references @id "${reference}" that is not declared on the page`);
    }
  }

  for (const type of typesSeen) {
    if (!ALLOWED_TYPES.has(type)) {
      fail(file, `JSON-LD uses @type "${type}", which is not in the allowed schema.org set`);
    }
  }

  const duplicateQuestions = questionNames.filter(
    (name, index) => questionNames.indexOf(name) !== index,
  );
  if (duplicateQuestions.length > 0) {
    fail(file, `duplicate FAQ question(s): ${[...new Set(duplicateQuestions)].join("; ")}`);
  }

  // --- lang ---------------------------------------------------------------------
  if (!/<html[^>]*\blang=["'][a-z]{2}/i.test(html)) fail(file, "missing lang on <html>");

  if (!noindex) indexablePaths.push(pagePath);
}

// --- sitemap --------------------------------------------------------------------
const sitemapFiles = (await readdir(distRoot)).filter(
  (name) => name.startsWith("sitemap-") && name.endsWith(".xml") && name !== "sitemap-index.xml",
);
if (sitemapFiles.length === 0) {
  fail("sitemap", "no sitemap-*.xml produced");
} else {
  const sitemapPaths = new Set();
  for (const name of sitemapFiles) {
    const xml = await readFile(path.join(distRoot, name), "utf8");
    const entries = [...xml.matchAll(/<url>([\s\S]*?)<\/url>/g)];
    if (entries.length === 0) fail(name, "sitemap contains no <url> entries");
    for (const [, entry] of entries) {
      const loc = entry.match(/<loc>([^<]+)<\/loc>/)?.[1];
      if (!loc) continue;
      const pathname = new URL(loc).pathname.replace(/\/+$/, "") || "/";
      sitemapPaths.add(pathname);
      if (!/<lastmod>/.test(entry)) fail(name, `sitemap entry ${loc} has no <lastmod>`);
    }
  }
  for (const pagePath of indexablePaths) {
    if (!sitemapPaths.has(pagePath)) fail("sitemap", `indexable page ${pagePath} is not listed`);
  }
}

// --- generated text files ---------------------------------------------------------
for (const artifact of ["llms.txt", "llms-full.txt", "rss.xml", "robots.txt"]) {
  const artifactPath = path.join(distRoot, artifact);
  try {
    const info = await stat(artifactPath);
    if (info.size === 0) fail(artifact, "is empty");
  } catch {
    fail(artifact, "was not produced by the build");
  }
}

// --- report -----------------------------------------------------------------------
for (const warning of warnings) console.warn(`warning  ${warning}`);

if (failures.length > 0) {
  console.error(`\nSEO checks failed (${failures.length}):`);
  for (const failure of failures) console.error(`  ${failure}`);
  process.exit(1);
}

console.log(
  `SEO checks passed: ${htmlFiles.length} pages, ${indexablePaths.length} indexable, sitemap and text artifacts present.`,
);
