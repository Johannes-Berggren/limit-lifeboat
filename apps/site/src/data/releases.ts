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
