import rss from "@astrojs/rss";
import type { APIRoute } from "astro";
import { product } from "../config";
import { guides } from "../data/pages";
import { releases } from "../data/releases";

/**
 * Combined feed of guides and releases, newest first.
 *
 * Guides use their dateModified so a substantive rewrite resurfaces; releases use their
 * publication date.
 */
export const GET: APIRoute = (context) => {
  const site = context.site ?? new URL(product.siteUrl);

  // Absolute links, because the helper would otherwise append a trailing slash to a
  // relative path and the site is configured with trailingSlash: "never".
  const absolute = (path: string) => `${product.siteUrl}${path}`;

  const guideItems = guides.map((guide) => ({
    title: guide.title,
    description: guide.summary,
    link: absolute(guide.path),
    pubDate: new Date(`${guide.dateModified}T09:00:00Z`),
    categories: ["Guide"],
  }));

  const releaseItems = releases.map((release) => ({
    title: `Limit Lifeboat ${release.version}`,
    description: release.highlights.join(" "),
    link: absolute(`/changelog#v${release.version}`),
    pubDate: new Date(`${release.date}T12:00:00Z`),
    categories: ["Release"],
  }));

  const items = [...guideItems, ...releaseItems].sort(
    (a, b) => b.pubDate.getTime() - a.pubDate.getTime(),
  );

  return rss({
    title: `${product.name} — guides and releases`,
    description: `New guides and release notes for ${product.name}, the Claude Code and Codex CLI account switcher for macOS.`,
    site,
    items,
    customData: "<language>en-us</language>",
  });
};
