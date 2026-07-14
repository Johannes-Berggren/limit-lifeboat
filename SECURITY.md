# Security Policy

## Supported versions

Security fixes are provided for the latest stable release of Limit Lifeboat.
Pre-release builds and older stable versions may be used to reproduce a report,
but users should update to the newest stable release to receive fixes.

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
