import productVersion from "../../macos/VERSION?raw";

const version = productVersion.trim();

if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(version)) {
  throw new Error(`apps/macos/VERSION must use stable major.minor.patch SemVer; found "${version}"`);
}

const dmgAsset = `Limit-Lifeboat-${version}-arm64.dmg`;

export const product = {
  name: "Limit Lifeboat",
  headline: "Switch Claude Code and Codex accounts without breaking your setup.",
  /** Long-form value proposition. Used as on-page copy, not as a meta description. */
  shortDescription:
    "Switch Claude Code and Codex CLI logins between your accounts on macOS. Only the auth fields change, the account is verified afterwards, and settings.json is never touched. Free and open source.",
  /** Meta description for the homepage. Kept inside the ~160 character display budget. */
  metaDescription:
    "Switch Claude Code and Codex CLI logins between your own accounts on macOS. Only the auth fields change, and the account is verified afterwards.",
  siteUrl: "https://limitlifeboat.com",
  version,
  minimumMacOS: "macOS 14 Sonoma",
  architecture: "Apple Silicon",
  bundleIdentifier: "com.limitlifeboat.app",
  author: {
    name: "Johannes Berggren",
    url: "https://github.com/Johannes-Berggren",
  },
  homebrewCommand:
    "brew install --cask Johannes-Berggren/tap/limit-lifeboat",
  links: {
    repository: "https://github.com/Johannes-Berggren/limit-lifeboat",
    download:
      `https://github.com/Johannes-Berggren/limit-lifeboat/releases/download/v${version}/${dmgAsset}`,
    latestRelease:
      "https://github.com/Johannes-Berggren/limit-lifeboat/releases/latest",
    releases:
      "https://github.com/Johannes-Berggren/limit-lifeboat/releases",
    issues:
      "https://github.com/Johannes-Berggren/limit-lifeboat/issues",
    newIssue:
      "https://github.com/Johannes-Berggren/limit-lifeboat/issues/new/choose",
    securityReport:
      "https://github.com/Johannes-Berggren/limit-lifeboat/security/advisories/new",
    license:
      "https://github.com/Johannes-Berggren/limit-lifeboat/blob/main/LICENSE",
  },
} as const;

export const navigation = [
  { label: "Features", href: "/#features" },
  { label: "How it works", href: "/#setup" },
  { label: "Is this allowed?", href: "/#allowed" },
  { label: "Guides", href: "/guides" },
  { label: "Download", href: "/download" },
] as const;
