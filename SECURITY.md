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
- **Credential bytes in argv, for oversized writes only.** Updates to Claude
  Code's Keychain item normally pipe the secret to `/usr/bin/security` through
  standard input. Apple's interactive reader has a fixed ~4096-byte line buffer,
  and a merged credential that preserves sibling keys such as `mcpOAuth`
  routinely exceeds it, so those writes fall back to a direct
  `add-generic-password -U … -X <hex>` invocation that carries the secret as an
  argv element. Process arguments on macOS are readable by other processes
  running as the same user (and by root), so during that call the credential is
  exposed to same-uid and root observers. It is not exposed to other users on
  the machine. `security` is the only writer the item's ACL trusts, so a native
  `SecItemUpdate` is not an alternative — it would prompt on every switch.
  Logged and printed invocations redact the secret in both the stdin and argv
  paths.

## App control socket

`limit-lifeboat refresh` and `limit-lifeboat switch` ask the running app to act
over a Unix domain socket, `control.sock`, in the app's Application Support
folder. That socket is the only way another process can make the app do
anything, so it is deliberately narrow:

- **Same user only.** On launch the app forces the folder to `0700` and creates
  the socket `0600`, both owned by the user, and fails closed if it cannot
  verify either. The kernel's peer credentials (`getpeereid`, i.e.
  `LOCAL_PEERCRED`) are checked on every connection, before a byte is read, and
  any peer whose effective uid differs from the app's is disconnected. The CLI
  checks the socket's owner and mode, and the server's uid, before sending.
  Any process running as the same user can use the socket. That user can
  already run `claude` or `codex` and drive the app through its UI, so this
  adds no capability beyond what that user has.
- **Intents only.** The protocol has two commands: `refresh [accountId]` and
  `switch <accountId>`. No credential, token, file path or label is accepted
  from the client, and no credential is ever returned. Capture, rename and
  remove are not offered.
- **No new credential path.** Both commands run through the app's existing
  workflows: the scheduled refresh, the Retry workflow, and the switch
  workflow with its provider gate, target preflight and rollback. A socket
  request has exactly the authority of a menu or notification click and goes
  through the same checks. Like a notification click, it runs
  non-interactively: it never opens a confirmation dialog, and a switch or
  refresh that would need one, or a login, is refused with the reason.
- **Bounded.** One request per connection, at most 16 KiB, read within 5
  seconds, and at most four connections at a time.

A stale socket from a crash is replaced only if it is a socket owned by the
user that nobody answers on. Anything else in its place is left alone, and the
app runs without the socket.

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
