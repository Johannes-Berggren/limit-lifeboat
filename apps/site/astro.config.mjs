import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";

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
    }),
  ],
});
