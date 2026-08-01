import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";
import { guides, staticPages } from "./src/data/pages.ts";

// lastmod, changefreq and priority all come from the page registry, so a page cannot reach
// the sitemap without a maintained modification date.
const routeMetadata = new Map([
  ...staticPages.map((page) => [
    page.path,
    { lastmod: page.dateModified, changefreq: page.changefreq, priority: page.priority },
  ]),
  ...guides.map((guide) => [
    guide.path,
    { lastmod: guide.dateModified, changefreq: "monthly", priority: 0.7 },
  ]),
]);

/** Sitemap entries arrive as absolute URLs, sometimes with a trailing slash. */
function pathOf(url) {
  const pathname = new URL(url).pathname.replace(/\/+$/, "");
  return pathname === "" ? "/" : pathname;
}

export default defineConfig({
  site: "https://limitlifeboat.com",
  output: "static",
  trailingSlash: "never",
  compressHTML: true,
  build: {
    assets: "_assets",
  },
  integrations: [
    sitemap({
      filter: (page) => !page.endsWith("/404"),
      serialize(item) {
        const metadata = routeMetadata.get(pathOf(item.url));
        if (!metadata) return item;
        return {
          ...item,
          lastmod: `${metadata.lastmod}T00:00:00+00:00`,
          changefreq: metadata.changefreq,
          priority: metadata.priority,
        };
      },
    }),
  ],
});
