/**
 * URL helpers. The server validates every link authoritatively; these only drive
 * the UI (accept shared text, platform badge, reject an unsafe server address).
 * URLs are parsed with a small explicit parser because React Native's global `URL`
 * has historically implemented only part of the standard.
 */

export type Platform = "youtube" | "facebook" | "tiktok" | "twitter" | "instagram";

const PLATFORM_DOMAINS: Record<Platform, readonly string[]> = {
  youtube: ["youtube.com", "youtu.be", "youtube-nocookie.com"],
  facebook: ["facebook.com", "fb.watch", "fb.com"],
  tiktok: ["tiktok.com"],
  twitter: ["twitter.com", "x.com"],
  instagram: ["instagram.com"],
};

export interface ParsedUrl {
  scheme: "http" | "https";
  host: string;
  port: number | null;
  path: string;
}

const URL_RE = /^(https?):\/\/([^/?#]*)([^?#]*)(?:\?[^#]*)?(?:#.*)?$/i;

export function parseUrl(value: string): ParsedUrl | null {
  const match = URL_RE.exec(value.trim());
  if (!match) return null;
  const authority = match[2];
  if (authority.includes("@") || authority === "") return null; // userinfo is never legitimate here
  let host = authority;
  let port: number | null = null;
  const bracketed = /^\[([0-9a-fA-F:.]+)\](?::(\d{1,5}))?$/.exec(authority);
  if (bracketed) {
    host = `[${bracketed[1].toLowerCase()}]`;
    port = bracketed[2] ? Number(bracketed[2]) : null;
  } else {
    const split = /^([^:]+)(?::(\d{1,5}))?$/.exec(authority);
    if (!split) return null;
    host = split[1].toLowerCase().replace(/\.$/, "");
    port = split[2] ? Number(split[2]) : null;
  }
  if (port !== null && (port < 1 || port > 65535)) return null;
  if (!/^(\[[0-9a-f:.]+\]|[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*)$/.test(host)) return null;
  return { scheme: match[1].toLowerCase() as "http" | "https", host, port, path: match[3] || "" };
}

export function detectPlatform(value: string): Platform | null {
  const parsed = parseUrl(value.includes("://") ? value : `https://${value}`);
  if (!parsed) return null;
  for (const platform of Object.keys(PLATFORM_DOMAINS) as Platform[]) {
    if (PLATFORM_DOMAINS[platform].some((d) => parsed.host === d || parsed.host.endsWith(`.${d}`))) return platform;
  }
  return null;
}

/** First supported video link inside shared text such as "Watch this! https://youtu.be/abc". */
export function extractVideoUrl(text: string | null | undefined): string | null {
  if (!text) return null;
  const candidates = text.match(/https?:\/\/[^\s<>"']+/gi) ?? [];
  for (const raw of candidates) {
    const url = raw.replace(/[.,;:!?)\]}>'"]+$/, "");
    if (detectPlatform(url)) return url;
  }
  return null;
}

export class ServerUrlError extends Error {}

function isPrivateHost(host: string): boolean {
  if (host === "localhost" || host.endsWith(".local") || host === "[::1]") return true;
  const octets = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!octets) return false;
  const [a, b] = [Number(octets[1]), Number(octets[2])];
  return a === 10 || a === 127 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) ||
    (a === 169 && b === 254);
}

/**
 * Turn what the user typed into the server's base URL. Cleartext http is accepted only
 * for addresses on the local network; anywhere else it would expose the API key and the
 * downloaded media to the network.
 */
export function normalizeServerUrl(input: string): string {
  const trimmed = input.trim();
  if (!trimmed) throw new ServerUrlError("Enter your Namao server address.");
  const parsed = parseUrl(trimmed.includes("://") ? trimmed : `https://${trimmed}`);
  if (!parsed) throw new ServerUrlError("That doesn't look like a valid server address.");
  if (parsed.scheme === "http" && !isPrivateHost(parsed.host)) {
    throw new ServerUrlError("Use https:// unless the server is on your local network.");
  }
  const port = parsed.port !== null ? `:${parsed.port}` : "";
  const path = parsed.path.replace(/\/+$/, "");
  return `${parsed.scheme}://${parsed.host}${port}${path}`;
}
