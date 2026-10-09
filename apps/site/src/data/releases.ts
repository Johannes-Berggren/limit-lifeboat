/**
 * Published release history, newest first.
 *
 * Add an entry as part of the release PR. `apps/macos/VERSION` remains the only
 * product-version source; this file is the human-readable record of what changed.
 * Every version here must correspond to a published, immutable GitHub tag.
 */

export interface Release {
  readonly version: string;
  /** Publication date of the GitHub release, ISO 8601, UTC. */
  readonly date: string;
  readonly highlights: readonly string[];
}

export const releases: readonly Release[] = [
  {
    version: "1.1.18",
    date: "2026-10-09",
    highlights: [
      "Fixed a loop that kept Limit Lifeboat near full CPU on one core while idle.",
      "Bundled the limit-lifeboat command-line tool in the app, with one-click status line setup.",
    ],
  },
  {
    version: "1.1.17",
    date: "2026-10-05",
    highlights: [
      "Made Codex Memory Guard setup approve its hook automatically and keep that approval when another tool rearranges the hook configuration, while preserving user and managed-policy choices.",
    ],
  },
  {
    version: "1.1.16",
    date: "2026-10-05",
    highlights: [
      "Extended Memory Guard to hold new Codex sessions during critical memory pressure, with opt-in hook setup that preserves existing Codex hooks.",
      "Enhanced the status line with prompt-cache state and Claude Code usage fallbacks when saved readings are stale.",
      "Polished usage-credit wording, Codex balance formatting, and guidance about restarting Codex after switching accounts.",
    ],
  },
  {
    version: "1.1.15",
    date: "2026-10-02",
    highlights: [
      "Added runway gauges, early quota-shortfall warnings, and optional session parking when usage will run out before reset.",
      "Added a compact icon-only menu bar mode and clearer recovery guidance when a Claude account reaches its limit.",
      "Hardened account switching for current Codex credential stores, Claude login files, plan tiers, and prompt-cache behavior.",
      "Refreshed the Claude Code and Codex guides for the latest upstream behavior.",
    ],
  },
  {
    version: "1.1.14",
    date: "2026-09-20",
    highlights: [
      "Added Memory Guard with live Claude Code session census, memory-pressure warnings, and optional holds on new sessions when memory is critical.",
      "Added Claude Code budget modes, cheaper-mode suggestions, cold-cache warnings, and a weekly digest showing where quota was spent.",
      "Added optional memory graphs in the menu bar and popover, including complete trends from the first reading.",
    ],
  },
  {
    version: "1.1.13",
    date: "2026-09-15",
    highlights: [
      "Fixed recovery login and account switching after Claude Code clears both tokens. Its exact logged-out state (empty accessToken and refreshToken with expiresAt: 0) is now recognized, while malformed credential data is still rejected.",
    ],
  },
  {
    version: "1.1.12",
    date: "2026-09-10",
    highlights: [
      "Fixed the profile-removal crash: removing a saved Claude profile now closes its dashboard safely, erases its isolated session data, and keeps the app running.",
    ],
  },
  {
    version: "1.1.11",
    date: "2026-09-03",
    highlights: [
      "Retried stale Claude Code Keychain item references after helper writes, preventing false switch failures when macOS hands back an outdated credential pointer.",
    ],
  },
  {
    version: "1.1.10",
    date: "2026-08-25",
    highlights: [
      "Absorbed Claude API throttling and Retry-After backoff so recent usage stays visible instead of turning into a refresh failure.",
    ],
  },
  {
    version: "1.1.9",
    date: "2026-08-16",
    highlights: [
      "Retired the orange pace badges in favor of a quieter gauge caption in the account menu.",
      "Fixed account-row timers, switch-advice edge cases, CLI reporting, usage parsing, and credential probing bugs.",
      "Added guides for checking the active Claude Code account and recovering lost Claude Code MCP servers.",
    ],
  },
  {
    version: "1.1.8",
    date: "2026-08-04",
    highlights: [
      "Expanded the marketing site with changelog, download, guide, RSS, sitemap, llms.txt, and answer-engine pages.",
      "Adjusted automatic account switching so near-limit accounts refresh more aggressively before a switch decision.",
    ],
  },
  {
    version: "1.1.7",
    date: "2026-07-31",
    highlights: [
      "Corrected the units used for Claude pay-as-you-go extra usage, which had been reporting spend far above the real figure.",
      "Added a read-only companion CLI that reports account usage without contacting a provider, writing to any credential store, or switching accounts.",
      "Reworked automatic switching so it can move off an account before it is fully depleted rather than only after.",
    ],
  },
  {
    version: "1.1.6",
    date: "2026-07-28",
    highlights: [
      "Prevented Claude usage from being attributed to the wrong saved account.",
      "Fixed three latent bugs and removed duplicated code paths across the macOS app.",
    ],
  },
  {
    version: "1.1.5",
    date: "2026-07-24",
    highlights: [
      "Made the Settings window scrollable and resizable.",
      "Switched to text provider labels and tightened menu-bar spacing.",
      "Fixed writing oversized Claude credentials, which previously failed to save.",
    ],
  },
  {
    version: "1.1.4",
    date: "2026-07-23",
    highlights: [
      "Fixed the crash on launch introduced in 1.1.3. If you are on 1.1.3, install this version or newer over it.",
    ],
  },
  {
    version: "1.1.3",
    date: "2026-07-23",
    highlights: [
      "Added automatic switching in your own saved priority order rather than by remaining capacity alone.",
      "Recovered expired Claude usage tokens for inactive accounts automatically.",
      "Moved Claude credential access onto Claude Code's own security backend.",
      "Added provider logos to the menu bar.",
    ],
  },
  {
    version: "1.1.2",
    date: "2026-07-22",
    highlights: ["Fixed Claude login recovery and Keychain refresh failures."],
  },
  {
    version: "1.1.1",
    date: "2026-07-21",
    highlights: [
      "Stopped premature Claude login expiry caused by two sessions rotating the same refresh token.",
      "Hardened Claude credential access and removed repeated Keychain prompts.",
      "Added controls for Codex earned rate-limit resets, off by default per account.",
    ],
  },
  {
    version: "1.1.0",
    date: "2026-07-19",
    highlights: [
      "Added usage history with CSV export, burn-rate pace alerts, a weekly digest, and per-account billing details.",
    ],
  },
  {
    version: "1.0.4",
    date: "2026-07-18",
    highlights: [
      "Repaired the Claude Keychain partition list in-app to stop repeated prompts during a switch.",
      "Reduced unexpected login expiry when the same account is used across more than one Mac.",
      "Fixed switch-confirmation alerts appearing behind the menu popover.",
    ],
  },
  {
    version: "1.0.3",
    date: "2026-07-16",
    highlights: ["Stopped recurring Keychain prompts for Claude Code credentials."],
  },
  {
    version: "1.0.2",
    date: "2026-07-16",
    highlights: [
      "Kept Codex usage current by reading through the locally installed Codex app server.",
      "Collapsed account usage gauges into a single row.",
      "Added app logging and a diagnostics export.",
    ],
  },
  {
    version: "1.0.1",
    date: "2026-07-15",
    highlights: [
      "Added user-confirmed in-app updates over a signed release feed.",
      "Allowed logging in to a non-active account without switching to it.",
    ],
  },
  {
    version: "1.0.0",
    date: "2026-07-15",
    highlights: ["First public release."],
  },
] as const;

export const latestRelease = releases[0];
