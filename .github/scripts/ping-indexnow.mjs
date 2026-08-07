#!/usr/bin/env node

/**
 * Submits every sitemap URL to IndexNow after a site deploy.
 *
 * IndexNow is a push protocol: instead of waiting for a crawler to rediscover the site, the
 * publisher tells the participating engines which URLs changed. Bing, Yandex, Seznam and
 * Naver consume it; Google does not, so this complements Search Console rather than
 * replacing it.
 *
 * The key is public by design — it lives at https://limitlifeboat.com/<key>.txt and the
 * engines fetch it to prove the submitter controls the host. There is no secret here and
 * nothing to configure in CI.
 *
 * This runs from a server, not a browser, so the site's `connect-src 'none'` CSP and its
 * published "no analytics" claim are both untouched.
 */

import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const distRoot = path.resolve(process.argv[2] ?? "apps/site/dist");
const host = "limitlifeboat.com";
const key = "bbf4344a67bb1c0a206d793346ec5861";
const endpoint = "https://api.indexnow.org/indexnow";

const sitemapFiles = (await readdir(distRoot)).filter(
  (name) => name.startsWith("sitemap-") && name.endsWith(".xml") && name !== "sitemap-index.xml",
);

const urlList = [];
for (const name of sitemapFiles) {
  const xml = await readFile(path.join(distRoot, name), "utf8");
  for (const [, loc] of xml.matchAll(/<loc>([^<]+)<\/loc>/g)) urlList.push(loc);
}

if (urlList.length === 0) {
  console.error(`No sitemap URLs found under ${distRoot}. Build the site first.`);
  process.exit(1);
}

const response = await fetch(endpoint, {
  method: "POST",
  headers: { "Content-Type": "application/json; charset=utf-8" },
  body: JSON.stringify({ host, key, keyLocation: `https://${host}/${key}.txt`, urlList }),
});

// 200 accepts the batch; 202 means accepted but the key is still being verified. Both are
// success. Anything else is worth seeing in the log, but none of it should fail a deploy —
// the site is already live either way.
if (response.ok) {
  console.log(`IndexNow accepted ${urlList.length} URLs (HTTP ${response.status}).`);
} else {
  console.warn(
    `IndexNow returned HTTP ${response.status}: ${await response.text()}`.trim(),
  );
}
