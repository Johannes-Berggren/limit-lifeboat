# Provider compatibility review — October 31, 2026

Reviewed Claude Code **2.1.316** and Codex CLI **0.166.0**, including the
changes since Limit Lifeboat 1.2.0. This is a compatibility review, not a
requirement to install those versions.

## Claude Code

- [2.1.312 renamed the session limit to “5-hour limit” and updated clock-time
  reset messages](https://github.com/anthropics/claude-code/releases/tag/v2.1.312).
  Lifeboat accepts that heading as well as “Current session” in its `/usage`
  fallback. Both retain the `session` window identity, including across TUI
  redraws, so existing history and alerts continue to refer to the same window.
  Reset descriptions such as “at 3:10 PM” use the existing reset-date parser.
- [2.1.314 fixed dotted model IDs behind gateways](https://github.com/anthropics/claude-code/releases/tag/v2.1.314).
  Lifeboat now retains their full version in session labels instead of dropping
  it. Hyphenated IDs and dated snapshots remain supported. Current Opus,
  Sonnet, Haiku and Fable names need no model allowlist.
- [The status-line contract](https://code.claude.com/docs/en/statusline)
  still supplies optional `prompt_cache`, `rate_limits.five_hour` and
  `rate_limits.seven_day` fields. Lifeboat continues to use only those
  subscription windows for its subscription percentage; a gateway's
  `spend_limit` is a separate budget.
- [2.1.316 added subagent effort configuration and deprecated Opus 4.8 fast
  mode](https://github.com/anthropics/claude-code/releases/tag/v2.1.316).
  Lifeboat's optional budget presets use model aliases, so they follow Claude's
  [provider-specific model resolution](https://code.claude.com/docs/en/model-config).
  Lifeboat does not enable fast mode or pin Opus 4.8.

## Codex

- [0.165.0](https://github.com/openai/codex/releases/tag/rust-v0.165.0) and
  [0.166.0](https://github.com/openai/codex/releases/tag/rust-v0.166.0) add
  GPT-6.1 Terra catalog entries, Vertex AI support and conversation effort
  changes. Lifeboat reads ChatGPT subscription usage independently of the
  model catalog and does not choose a conversation's provider or model.
- [The app-server contract](https://developers.openai.com/codex/app-server#auth-endpoints)
  continues to expose `account/read`, `account/rateLimits/read` and
  `account/rateLimitResetCredit/consume`. The earned-reset count is still
  authoritative, and redemption still uses an idempotency key followed by a
  fresh limits read.
- Rate limits include a bucket identifier. Lifeboat prefers the `codex` entry
  in `rateLimitsByLimitId`. Its single-bucket app-server fallback and
  [local `token_count` log reader](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/protocol/src/protocol.rs)
  now reject explicitly different bucket IDs rather than treating a
  model-specific quota as the account's main quota. Local scanning continues
  backward to find the latest main-bucket event and retains the account
  activation freshness gate. Legacy readings without a bucket ID still work.
- Local log parsing ignores non-finite percentages and reset times, and
  unrepresentable window durations, instead of risking an integer-conversion
  crash on malformed data.

## Validation scope

Regression fixtures cover both Claude headings, clock resets, mixed TUI
redraws, current model names, main and model-specific Codex buckets, legacy
bucket-less responses, account activation freshness, and malformed numbers.
Tests use synthetic credentials and logs. This review does not redeem a
reset, refresh a real account, switch a login, or upgrade the installed CLIs.
