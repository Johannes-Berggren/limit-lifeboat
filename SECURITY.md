# Security Policy

## Supported versions

Security fixes are provided for the latest stable release of Limit Lifeboat.
Pre-release builds and older stable versions may be used to reproduce a report,
but users should update to the newest stable release to receive fixes.

## Credential handling

Limit Lifeboat reads and switches CLI authentication material. A few properties
of that handling are worth stating explicitly:

- **At-rest storage.** Account credential snapshots are stored in the macOS
  Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so they are
  not synced to iCloud and are excluded from device backups. The app never
  recreates Claude Code's own live Keychain item; it only updates its value,
  preserving the CLI's existing access control.
- **Transient plaintext during a switch.** While switching or restoring an
  account, the current credentials are copied out of the Keychain into
  short-lived rollback files under
  `~/Library/Application Support/LimitLifeboat/Backups/`. These files are
  written with `0600` permissions inside a `0700` directory and are deleted once
  the switch commits or rolls back successfully. Codex preflight similarly
  writes `auth.json` to a `0700` per-user temporary directory that is removed
  after the check.
- **Retained recovery directory.** If a rollback itself fails (a conflicting
  concurrent change), the recovery directory is intentionally retained so the
  credentials can be restored manually, rather than being deleted. In that case
  the `0600` rollback files remain on disk under Application Support until you
  remove them.

These files are protected by POSIX permissions rather than Keychain encryption
while they exist. Consider excluding the Application Support directory from
unencrypted backups if that is part of your threat model.

## Report a vulnerability

Use
[GitHub private vulnerability reporting](https://github.com/Johannes-Berggren/limit-lifeboat/security/advisories/new)
to report a suspected vulnerability. Please do not open a public issue or
discussion for an undisclosed security problem.

Include enough information to reproduce and assess the issue:

- The affected Limit Lifeboat version and macOS version
- The expected and observed behavior
- Minimal reproduction steps or a proof of concept
- The likely impact, if known
- Any suggested remediation

Limit Lifeboat handles CLI authentication material. Do not include real access
tokens, refresh tokens, session cookies, passwords, private keys, full Keychain
exports, or unredacted account data. Replace secrets and personal information
with clearly marked test values before attaching logs, screenshots, backups, or
sample configuration files.

The report will remain private while it is investigated. Please allow time to
confirm the issue and coordinate a fix before public disclosure. Once a fix is
available, the GitHub security advisory can be used to coordinate publication
and credit.

For ordinary bugs and feature requests that have no security impact, use the
repository's public issue tracker.
