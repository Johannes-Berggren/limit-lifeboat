#!/usr/bin/env node

import { readdir, readFile, stat } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const siteRoot = path.resolve(process.argv[2] ?? "apps/site/dist");

// Every route the site is expected to publish. A page removed by accident fails the build
// here rather than turning into a 404 in production.
const expectedPages = [
  "index.html",
  "404.html",
  "privacy/index.html",
  "support/index.html",
  "download/index.html",
  "changelog/index.html",
  "guides/index.html",
  "guides/switch-claude-code-accounts-mac/index.html",
  "guides/manage-multiple-codex-accounts-mac/index.html",
  "guides/claude-code-codex-usage-monitor-mac/index.html",
  "guides/claude-code-account-switchers-compared/index.html",
  "guides/claude-code-usage-limits-explained/index.html",
  "guides/codex-cli-rate-limits-explained/index.html",
  "guides/claude-code-limit-reached/index.html",
  "guides/multiple-claude-accounts-allowed/index.html",
  "guides/work-and-personal-claude-accounts/index.html",
  "llms.txt",
  "llms-full.txt",
  "rss.xml",
  "robots.txt",
  "sitemap-index.xml",
];

async function filesBelow(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => {
    const entryPath = path.join(directory, entry.name);
    return entry.isDirectory() ? filesBelow(entryPath) : [entryPath];
  }));
  return nested.flat();
}

async function exists(candidate) {
  try {
    return (await stat(candidate)).isFile();
  } catch {
    return false;
  }
}

function publicPathFor(htmlPath) {
  const relativePath = path.relative(siteRoot, htmlPath).split(path.sep).join("/");
  if (relativePath === "index.html") return "/";
  if (relativePath.endsWith("/index.html")) return `/${relativePath.slice(0, -"index.html".length)}`;
  return `/${relativePath}`;
}

function candidatesFor(pathname) {
  const decoded = decodeURIComponent(pathname);
  const relative = decoded.replace(/^\/+/, "");
  const base = path.resolve(siteRoot, relative);
  if (!base.startsWith(`${siteRoot}${path.sep}`) && base !== siteRoot) return [];
  if (decoded.endsWith("/")) return [path.join(base, "index.html")];
  if (path.extname(decoded)) return [base];
  return [base, `${base}.html`, path.join(base, "index.html")];
}

for (const expectedPage of expectedPages) {
  if (!await exists(path.join(siteRoot, expectedPage))) {
    throw new Error(`Expected generated page is missing: ${expectedPage}`);
  }
}

const htmlFiles = (await filesBelow(siteRoot)).filter((file) => file.endsWith(".html"));
const failures = [];

for (const htmlFile of htmlFiles) {
  const html = await readFile(htmlFile, "utf8");
  const sourceURL = new URL(publicPathFor(htmlFile), "https://limitlifeboat.com");
  for (const match of html.matchAll(/\bhref\s*=\s*["']([^"']+)["']/gi)) {
    const href = match[1];
    if (!href || href.startsWith("#") || /^(mailto|tel|javascript|data):/i.test(href)) continue;

    const targetURL = new URL(href, sourceURL);
    if (targetURL.origin !== sourceURL.origin) continue;
    const candidates = candidatesFor(targetURL.pathname);
    if (!(await Promise.all(candidates.map(exists))).some(Boolean)) {
      failures.push(`${path.relative(siteRoot, htmlFile)} -> ${href}`);
    }
  }
}

if (failures.length > 0) {
  console.error("Broken internal links:\n" + failures.map((failure) => `  ${failure}`).join("\n"));
  process.exitCode = 1;
} else {
  console.log(`Checked internal links in ${htmlFiles.length} generated HTML files.`);
}
