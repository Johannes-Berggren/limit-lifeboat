import productVersion from "../../macos/VERSION?raw";

const version = productVersion.trim();

if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(version)) {
  throw new Error(`apps/macos/VERSION must use stable major.minor.patch SemVer; found "${version}"`);
}

const dmgAsset = `Limit-Lifeboat-${version}-arm64.dmg`;

export const product = {
  name: "Limit Lifeboat",
  headline: "Keep every AI coding account afloat.",
  shortDescription:
    "A native macOS menu-bar app for seeing Claude and ChatGPT/Codex usage, getting timely warnings, and safely switching CLI accounts.",
  siteUrl: "https://limitlifeboat.com",
  version,
  minimumMacOS: "macOS 14 Sonoma",
  architecture: "Apple Silicon",
  bundleIdentifier: "com.limitlifeboat.app",
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
  { label: "Security", href: "/#security" },
] as const;
