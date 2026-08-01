/**
 * Single source of truth for every indexable route.
 *
 * The sitemap (lastmod), the /guides hub, /llms.txt, /llms-full.txt and /rss.xml all
 * read from here, so those four cannot drift apart. Guide pages import their own
 * metadata from `getGuide()` rather than repeating it in frontmatter.
 */

export type GuideGroupId = "switching" | "limits" | "policy" | "troubleshooting";

export interface GuideMeta {
  /** Site-absolute path, no trailing slash. */
  readonly path: string;
  /** Rendered as the <h1> and as schema.org `headline`. */
  readonly title: string;
  /** Shorter variant for the <title> tag when the h1 would truncate in results. */
  readonly metaTitle: string;
  /** Meta description. Aim for 120-160 characters. */
  readonly description: string;
  /** One sentence for the hub grid, llms.txt and the RSS item. */
  readonly summary: string;
  readonly eyebrow: string;
  readonly group: GuideGroupId;
  /** ISO 8601 date. */
  readonly datePublished: string;
  /** ISO 8601 date. Bump whenever the body copy changes materially. */
  readonly dateModified: string;
  readonly readingTime: string;
  readonly imageAlt: string;
  readonly figcaption: string;
}

export interface GuideGroup {
  readonly id: GuideGroupId;
  readonly name: string;
  readonly blurb: string;
}

export const guideGroups: readonly GuideGroup[] = [
  {
    id: "switching",
    name: "Switching accounts",
    blurb:
      "Move a CLI between logins you are authorized to use, without replacing the configuration around them.",
  },
  {
    id: "limits",
    name: "Usage limits",
    blurb:
      "What the session, weekly, and model-scoped windows actually measure, and what to do when one runs out.",
  },
  {
    id: "policy",
    name: "Policy and boundaries",
    blurb:
      "Where provider terms draw the line, and how to keep an employer-provisioned account separate from a personal one.",
  },
  {
    id: "troubleshooting",
    name: "Troubleshooting",
    blurb: "Fixing the authentication failures that interrupt a working session.",
  },
] as const;

export const guides: readonly GuideMeta[] = [
  {
    path: "/guides/switch-claude-code-accounts-mac",
    title: "How to Switch Between Claude Code Accounts on Mac",
    metaTitle: "How to Switch Claude Code Accounts on Mac",
    description:
      "Switch work and personal Claude Code accounts on Mac while keeping settings.json, MCP servers, instructions, and local history in place.",
    summary:
      "The official login flow, why repeated logins get awkward, and how to change authentication without replacing the rest of your CLI configuration.",
    eyebrow: "Claude Code account guide",
    group: "switching",
    datePublished: "2026-07-15",
    dateModified: "2026-08-01",
    readingTime: "6 minute read",
    imageAlt:
      "Limit Lifeboat showing separate Personal, Work, and Client Claude Code accounts with usage meters and an active-account indicator.",
    figcaption:
      "The active Claude Code login stays visible, so a switch is something you confirm rather than assume.",
  },
  {
    path: "/guides/manage-multiple-codex-accounts-mac",
    title: "How to Use Multiple Codex CLI Accounts on Mac",
    metaTitle: "Use Multiple Codex CLI Accounts on Mac",
    description:
      "Manage work and personal Codex CLI accounts on Mac, verify which login the CLI is really using, and switch without replacing unrelated Codex settings.",
    summary:
      "Codex CLI caches its own login independently of ChatGPT on the web. Here is how to verify the CLI identity and switch it deliberately.",
    eyebrow: "Codex CLI account guide",
    group: "switching",
    datePublished: "2026-07-15",
    dateModified: "2026-08-01",
    readingTime: "6 minute read",
    imageAlt:
      "Limit Lifeboat showing a Codex CLI account alongside separate Claude Code accounts, with usage and active-login status.",
    figcaption:
      "Codex CLI and ChatGPT on the web are separate surfaces, and the menu bar shows which one the CLI is on.",
  },
  {
    path: "/guides/claude-code-account-switchers-compared",
    title: "Claude Code Account Switchers Compared",
    metaTitle: "Claude Code Account Switchers Compared",
    description:
      "An honest comparison of the tools that switch Claude Code and Codex CLI logins on macOS, covering write scope, verification, rollback, and licensing.",
    summary:
      "How Limit Lifeboat, claude-swap, clauth, cc-account-switcher and the menu-bar monitors differ on write scope, verification, and rollback.",
    eyebrow: "Comparison",
    group: "switching",
    datePublished: "2026-08-01",
    dateModified: "2026-08-01",
    readingTime: "8 minute read",
    imageAlt:
      "Limit Lifeboat menu-bar dashboard listing several saved Claude Code and Codex CLI accounts with their remaining usage.",
    figcaption:
      "Every tool here moves a credential. They differ in what else they touch on the way through.",
  },
  {
    path: "/guides/claude-code-usage-limits-explained",
    title: "Claude Code Usage Limits Explained",
    metaTitle: "Claude Code Usage Limits Explained",
    description:
      "How the Claude Code session window, weekly all-models cap, and model-scoped weekly windows work, how they reset, and how to read them accurately.",
    summary:
      "The five-hour session window, the weekly all-models cap, and the model-scoped weekly windows, and how each one rolls over.",
    eyebrow: "Usage limits reference",
    group: "limits",
    datePublished: "2026-08-01",
    dateModified: "2026-08-01",
    readingTime: "7 minute read",
    imageAlt:
      "Limit Lifeboat showing a Claude Code account with separate session, weekly all-models, and model-scoped usage meters.",
    figcaption:
      "Claude Code reports several windows at once. The tightest one is the one that stops you.",
  },
  {
    path: "/guides/codex-cli-rate-limits-explained",
    title: "Codex CLI Rate Limits Explained",
    metaTitle: "Codex CLI Rate Limits Explained",
    description:
      "How Codex CLI rate limit windows are reported, what earned rate-limit resets are, and how to read remaining Codex capacity before starting a task.",
    summary:
      "How Codex reports its rolling and multi-day windows, and what OpenAI's earned rate-limit resets actually are.",
    eyebrow: "Usage limits reference",
    group: "limits",
    datePublished: "2026-08-01",
    dateModified: "2026-08-01",
    readingTime: "6 minute read",
    imageAlt:
      "Limit Lifeboat showing a Codex CLI account with its reported rate limit windows and an earned reset badge.",
    figcaption:
      "Codex windows are labelled from the durations OpenAI reports, not from a fixed assumption.",
  },
  {
    path: "/guides/claude-code-limit-reached",
    title: "Claude Code Usage Limit Reached: What to Do",
    metaTitle: "Claude Code Usage Limit Reached: Options",
    description:
      "You hit the Claude Code usage limit. Here are the real options: wait for the window, add extra usage, change model, or move to another account you own.",
    summary:
      "A decision guide for the moment Claude Code stops: wait, buy extra usage, drop to a cheaper model, or move to another authorized account.",
    eyebrow: "Decision guide",
    group: "limits",
    datePublished: "2026-08-01",
    dateModified: "2026-08-01",
    readingTime: "6 minute read",
    imageAlt:
      "Limit Lifeboat showing one depleted Claude Code account and another with remaining weekly capacity.",
    figcaption:
      "Seeing which account still has headroom turns a hard stop into a decision.",
  },
  {
    path: "/guides/claude-code-codex-usage-monitor-mac",
    title: "How to Monitor Claude Code and Codex Usage on Mac",
    metaTitle: "Monitor Claude Code & Codex Usage on Mac",
    description:
      "Monitor Claude Code and Codex usage limits from the Mac menu bar, understand reset windows and stale readings, and get optional warnings before interruptions.",
    summary:
      "Checking usage once is easy. Seeing every account, spotting a stale reading, and knowing whether a task fits is the harder problem.",
    eyebrow: "AI coding usage guide",
    group: "limits",
    datePublished: "2026-07-15",
    dateModified: "2026-08-01",
    readingTime: "7 minute read",
    imageAlt:
      "Limit Lifeboat menu-bar dashboard showing session and weekly usage meters for three Claude Code accounts and one Codex CLI account.",
    figcaption:
      "Every saved account, its tightest window, and how old the reading is, in one menu-bar view.",
  },
  {
    path: "/guides/multiple-claude-accounts-allowed",
    title: "Are Multiple Claude Code Accounts Allowed?",
    metaTitle: "Are Multiple Claude Code Accounts Allowed?",
    description:
      "What Anthropic and OpenAI terms actually prohibit, what account switching does and does not do, and how to decide whether your own setup is within policy.",
    summary:
      "Separating the things providers actually prohibit from the things people assume they prohibit, without telling you your setup is fine.",
    eyebrow: "Policy and boundaries",
    group: "policy",
    datePublished: "2026-08-01",
    dateModified: "2026-08-01",
    readingTime: "7 minute read",
    imageAlt:
      "Limit Lifeboat showing separate saved accounts, each with its own provider-enforced usage windows.",
    figcaption:
      "Quotas stay separate and provider-enforced. Nothing here is pooled, merged, or extended.",
  },
  {
    path: "/guides/work-and-personal-claude-accounts",
    title: "Keeping Work and Personal Claude Accounts Separate",
    metaTitle: "Work and Personal Claude Code Accounts",
    description:
      "Run an employer-provisioned Claude or ChatGPT account alongside a personal one on the same Mac without mixing up which identity your CLI is billing.",
    summary:
      "The employer-provisioned plus personal case: keeping the boundary visible, and what to check before touching client material.",
    eyebrow: "Policy and boundaries",
    group: "policy",
    datePublished: "2026-08-01",
    dateModified: "2026-08-01",
    readingTime: "6 minute read",
    imageAlt:
      "Limit Lifeboat showing a work account and a personal account with distinct labels and separate usage meters.",
    figcaption:
      "The risk is not running out of quota. It is spending an afternoon billing the wrong employer.",
  },
  {
    path: "/guides/claude-code-login-expired",
    title: "Fixing Claude Code Login Expired and Repeated Logouts",
    metaTitle: "Fix Claude Code Login Expired on Mac",
    description:
      "Why Claude Code asks you to log in again, what causes repeated logouts across parallel sessions, and how to recover the login without losing your setup.",
    summary:
      "What causes the repeated Claude Code logout loop, the recovery order that works, and how to avoid re-triggering it.",
    eyebrow: "Troubleshooting",
    group: "troubleshooting",
    datePublished: "2026-08-01",
    dateModified: "2026-08-01",
    readingTime: "7 minute read",
    imageAlt:
      "Limit Lifeboat showing a Claude Code account whose saved login has expired, with a Log In action available.",
    figcaption:
      "An expired login stays actionable instead of silently reporting stale usage.",
  },
] as const;

/** Non-guide indexable routes, for sitemap lastmod and llms.txt. */
export interface StaticPageMeta {
  readonly path: string;
  readonly title: string;
  readonly summary: string;
  /** Category line on the generated Open Graph card. Must not repeat the wordmark. */
  readonly kicker: string;
  readonly dateModified: string;
  readonly changefreq: "daily" | "weekly" | "monthly" | "yearly";
  readonly priority: number;
}

export const staticPages: readonly StaticPageMeta[] = [
  {
    path: "/",
    title: "Claude Code & Codex Account Switcher for Mac",
    summary:
      "The product overview: transactional switching, per-account usage, and where the policy line sits.",
    kicker: "Free and open source",
    dateModified: "2026-08-01",
    changefreq: "weekly",
    priority: 1,
  },
  {
    path: "/guides",
    title: "Claude Code and Codex Guides",
    summary: "Every guide, grouped by switching, usage limits, policy, and troubleshooting.",
    kicker: "Practical guides",
    dateModified: "2026-08-01",
    changefreq: "weekly",
    priority: 0.8,
  },
  {
    path: "/download",
    title: "Download Limit Lifeboat for Mac",
    summary:
      "Homebrew cask and signed DMG install instructions, requirements, first-run permissions, and update behaviour.",
    kicker: "Signed and notarized",
    dateModified: "2026-08-01",
    changefreq: "weekly",
    priority: 0.9,
  },
  {
    path: "/changelog",
    title: "Limit Lifeboat Changelog",
    summary: "Release notes for every published version.",
    kicker: "Release notes",
    dateModified: "2026-08-01",
    changefreq: "weekly",
    priority: 0.6,
  },
  {
    path: "/support",
    title: "Support",
    summary: "Install, account, switching, and permission troubleshooting, plus how to report a bug.",
    kicker: "Help and troubleshooting",
    dateModified: "2026-08-01",
    changefreq: "monthly",
    priority: 0.6,
  },
  {
    path: "/privacy",
    title: "Privacy",
    summary: "What the app and this website store, and when the app uses the network.",
    kicker: "Privacy and data",
    dateModified: "2026-08-01",
    changefreq: "yearly",
    priority: 0.3,
  },
] as const;

export function getGuide(path: string): GuideMeta {
  const guide = guides.find((entry) => entry.path === path);
  if (!guide) throw new Error(`Unknown guide path: ${path}. Add it to src/data/pages.ts.`);
  return guide;
}

export function guidesInGroup(group: GuideGroupId): readonly GuideMeta[] {
  return guides.filter((guide) => guide.group === group);
}

/** Guides other than `path`, for contextual cross-links. Same group first. */
export function relatedGuides(path: string, limit = 3): readonly GuideMeta[] {
  const current = getGuide(path);
  const others = guides.filter((guide) => guide.path !== path);
  const sameGroup = others.filter((guide) => guide.group === current.group);
  const rest = others.filter((guide) => guide.group !== current.group);
  return [...sameGroup, ...rest].slice(0, limit);
}

/** Every indexable route with the date the sitemap should advertise. */
export function allRouteDates(): ReadonlyMap<string, string> {
  return new Map<string, string>([
    ...staticPages.map((page) => [page.path, page.dateModified] as const),
    ...guides.map((guide) => [guide.path, guide.dateModified] as const),
  ]);
}

/** Slug used by the generated Open Graph card: "/" is "home", "/guides/x" is "guides-x". */
export function ogSlugFor(path: string): string {
  if (path === "/") return "home";
  return path.replace(/^\//, "").replace(/\//g, "-");
}

/** Site-absolute path of the generated Open Graph card for a route. */
export function ogImageFor(path: string): string {
  return `/og/${ogSlugFor(path)}.png`;
}

/** Every card the OG endpoint actually generates, so layouts can fall back safely. */
export const ogCardPaths: ReadonlySet<string> = new Set(
  [...staticPages.map((page) => page.path), ...guides.map((guide) => guide.path)].map(ogImageFor),
);

export function formatLongDate(isoDate: string): string {
  return new Date(`${isoDate}T00:00:00Z`).toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
    timeZone: "UTC",
  });
}
