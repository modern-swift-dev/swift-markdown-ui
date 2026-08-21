export interface Release {
  tag: string;
  version: string;
  publishedAt: Date;
  url: string;
}

interface GitHubRelease {
  draft: boolean;
  prerelease: boolean;
  tag_name: string;
  published_at: string | null;
  html_url: string;
}

const latestReleaseURL = "https://api.github.com/repos/modern-swift-dev/swift-markdown-ui/releases/latest";
const semver = /^v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)$/;

function isGitHubRelease(value: unknown): value is GitHubRelease {
  if (typeof value !== "object" || value === null) return false;
  const release = value as Record<string, unknown>;
  return typeof release.draft === "boolean" && typeof release.prerelease === "boolean" &&
    typeof release.tag_name === "string" && (typeof release.published_at === "string" || release.published_at === null) &&
    typeof release.html_url === "string";
}

export async function getLatestPublishedRelease(): Promise<Release> {
  let response: Response;
  try {
    response = await fetch(latestReleaseURL, { headers: { Accept: "application/vnd.github+json" } });
  } catch (error) {
    throw new Error(`Could not fetch MarkdownUI releases: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (!response.ok) throw new Error(`Could not fetch MarkdownUI releases: GitHub returned HTTP ${response.status}.`);

  const latest: unknown = await response.json();
  if (!isGitHubRelease(latest)) throw new Error("Could not fetch MarkdownUI releases: GitHub returned an invalid release payload.");
  if (latest.draft || latest.prerelease) throw new Error("Could not fetch MarkdownUI releases: GitHub returned a draft or prerelease.");

  const match = semver.exec(latest.tag_name);
  if (!match) throw new Error(`Could not fetch MarkdownUI releases: tag \"${latest.tag_name}\" is not a semantic version.`);
  if (!latest.published_at) throw new Error(`Could not fetch MarkdownUI releases: tag \"${latest.tag_name}\" has no publication date.`);
  const publishedAt = new Date(latest.published_at);
  if (Number.isNaN(publishedAt.getTime())) throw new Error(`Could not fetch MarkdownUI releases: tag \"${latest.tag_name}\" has an invalid publication date.`);
  let url: URL;
  try { url = new URL(latest.html_url); } catch { throw new Error(`Could not fetch MarkdownUI releases: tag \"${latest.tag_name}\" has an invalid release URL.`); }
  const expectedPath = `/modern-swift-dev/swift-markdown-ui/releases/tag/${encodeURIComponent(latest.tag_name)}`;
  if (url.protocol !== "https:" || url.hostname !== "github.com" || url.pathname !== expectedPath) {
    throw new Error(`Could not fetch MarkdownUI releases: tag \"${latest.tag_name}\" has an unexpected release URL.`);
  }
  return { tag: latest.tag_name, version: match[1], publishedAt, url: url.href };
}
