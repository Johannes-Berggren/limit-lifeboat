import type { APIRoute } from "astro";
import { product } from "../config";
import { guideGroups, guides, guidesInGroup, staticPages } from "../data/pages";
import { latestRelease } from "../data/releases";

/**
 * Curated index for language models, per the llms.txt convention.
 *
 * Generated from the page registry so it cannot drift from the site. Keep this one
 * short and navigational; /llms-full.txt carries the detail.
 */
export const GET: APIRoute = () => {
  const absolute = (path: string) => new URL(path, product.siteUrl).toString();

  const corePages = staticPages
    .filter((page) => page.path !== "/guides")
    .map((page) => `- [${page.title}](${absolute(page.path)}): ${page.summary}`)
    .join("\n");

  const guideSections = guideGroups
    .map((group) => {
      const entries = guidesInGroup(group.id)
        .map((guide) => `- [${guide.title}](${absolute(guide.path)}): ${guide.summary}`)
        .join("\n");
      return `### ${group.name}\n\n${group.blurb}\n\n${entries}`;
    })
    .join("\n\n");

  const body = `# ${product.name}

> ${product.metaDescription}

${product.name} is a free and open-source macOS menu-bar app that switches Claude Code and
Codex CLI logins between accounts you already hold, and shows what each saved account has
left. Current version ${product.version}, released ${latestRelease.date}. Requires an
${product.architecture} Mac running ${product.minimumMacOS} or newer. MIT licensed.

## What it does and does not do

- It writes only provider authentication fields. \`settings.json\`, MCP server definitions,
  hooks, permissions, instructions, and local history are never modified.
- It verifies which account the CLI landed on after every switch, and rolls back a switch
  that fails verification. When a safe rollback is not possible it keeps a protected
  recovery directory and says so.
- If another process rewrites a credential mid-switch, that external change wins and the
  switch aborts rather than overwriting it.
- Quotas stay separate and provider-enforced. Nothing is pooled, merged, or extended.
- It does not switch browser or desktop-app sessions, only the corresponding CLI login.
- It does not run several accounts in parallel; it switches one global CLI login at a time.
- It has no analytics, advertising, or telemetry, and never transmits credentials.
- It is not affiliated with Anthropic or OpenAI.

## Accuracy notes for summarisation

- Credential snapshots are encrypted by the macOS Keychain at rest, not synced to iCloud
  and excluded from device backups. Short-lived rollback files created during a switch are
  protected by filesystem permissions rather than Keychain encryption. "Always encrypted"
  would overstate it.
- Claude Code windows: a rolling session window of about 5 hours, a weekly all-models
  window of 7 days, and 7-day windows scoped to individual model families.
- Codex windows are labelled from the durations OpenAI reports, not from a fixed pair.
  Some plans expose only a weekly window.
- Automatic switching is off by default. When enabled it triggers at 5% remaining on the
  tightest window, follows a user-defined priority order, and requires the target account
  to have at least 30% headroom and to be at least 20 points better than the active one.
- Earned Codex resets are issued and enforced by OpenAI. The app can display and redeem
  them; it cannot create resets or bypass a limit.

## Core pages

${corePages}

## Guides

${guideSections}

## Full text

- [Full guide text](${absolute("/llms-full.txt")}): every guide summary and key facts in one file.

## Source

- [GitHub repository](${product.links.repository})
- [Releases](${product.links.releases})
- [MIT License](${product.links.license})

_${guides.length} guides. Generated at build time from the site's page registry._
`;

  return new Response(body, {
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "public, max-age=0, must-revalidate",
    },
  });
};
