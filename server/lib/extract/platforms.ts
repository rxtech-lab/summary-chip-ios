import { parseHTML } from "linkedom";
import type { SummarySource } from "@/lib/db/schema";
import { decodeText, fetchPublicDocument } from "./fetch";
import { normalizeWhitespace } from "./html";

export type Platform = Extract<SummarySource, "x" | "facebook" | "youtube" | "github">;

const PLATFORM_HOSTS: Record<Platform, string[]> = {
  x: ["x.com", "twitter.com"],
  facebook: ["facebook.com", "fb.com", "fb.watch"],
  youtube: ["youtube.com", "youtu.be", "youtube-nocookie.com"],
  github: ["github.com"],
};

/** The social or code platform a URL belongs to (subdomains included), or `null` for the open web. */
export function platformOf(url: string | null | undefined): Platform | null {
  if (!url) return null;
  let host: string;
  try {
    host = new URL(url).hostname.toLowerCase();
  } catch {
    return null;
  }
  for (const [platform, domains] of Object.entries(PLATFORM_HOSTS) as [Platform, string[]][]) {
    if (domains.some((domain) => host === domain || host.endsWith(`.${domain}`))) return platform;
  }
  return null;
}

export interface PlatformExtraction {
  text: string;
  title: string | null;
  siteName: string;
  imageUrl: string | null;
}

/**
 * Dedicated extractors for pages whose HTML holds little readable text (posts rendered by script,
 * videos). `null` means "not handled": the caller falls back to the generic page extractor.
 */
export async function extractFromPlatform(url: string): Promise<PlatformExtraction | null> {
  switch (platformOf(url)) {
    case "x": return extractXPost(url);
    case "youtube": return extractYouTubeVideo(url);
    default: return null;
  }
}

async function fetchJson(url: string): Promise<unknown> {
  const document = await fetchPublicDocument(url, { accept: "application/json", maxBytes: 2 * 1024 * 1024 });
  return JSON.parse(decodeText(document.bytes, document.charset));
}

/** A single post via the public oEmbed endpoint, which needs no login (the post page itself does). */
async function extractXPost(url: string): Promise<PlatformExtraction | null> {
  if (!/\/status(?:es)?\/\d+/.test(new URL(url).pathname)) return null;
  const endpoint = `https://publish.twitter.com/oembed?omit_script=1&dnt=true&url=${encodeURIComponent(url)}`;
  const embed = await fetchJson(endpoint) as { html?: string; author_name?: string };
  if (!embed.html) return null;
  const { document } = parseHTML(`<html><body>${embed.html}</body></html>`) as unknown as { document: Document };
  const post = document.querySelector("blockquote p");
  for (const br of post?.querySelectorAll("br") ?? []) br.replaceWith("\n");
  const text = normalizeWhitespace(post?.textContent ?? "");
  if (!text) return null;
  const author = embed.author_name?.trim() || null;
  return {
    text: author ? `Post by ${author}:\n\n${text}` : text,
    title: author ? `${author} on X` : null,
    siteName: "X",
    imageUrl: null,
  };
}

function youTubeVideoId(url: string): string | null {
  const parsed = new URL(url);
  const id = parsed.hostname.endsWith("youtu.be")
    ? parsed.pathname.split("/")[1]
    : parsed.searchParams.get("v") ?? parsed.pathname.match(/^\/(?:shorts|embed|live|v)\/([^/?#]+)/)?.[1];
  return id && /^[\w-]{6,20}$/.test(id) ? id : null;
}

interface YouTubePlayerResponse {
  videoDetails?: { title?: string; author?: string; shortDescription?: string; thumbnail?: { thumbnails?: { url: string }[] } };
  captions?: { playerCaptionsTracklistRenderer?: { captionTracks?: { baseUrl: string; languageCode?: string; kind?: string }[] } };
}

/** The JSON object assigned to `ytInitialPlayerResponse` in the watch page. */
function playerResponseFrom(html: string): YouTubePlayerResponse | null {
  const start = html.search(/ytInitialPlayerResponse\s*=\s*\{/);
  if (start < 0) return null;
  const open = html.indexOf("{", start);
  let depth = 0;
  let inString = false;
  for (let index = open; index < html.length; index += 1) {
    const char = html[index];
    if (inString) {
      if (char === "\\") index += 1;
      else if (char === "\"") inString = false;
    } else if (char === "\"") {
      inString = true;
    } else if (char === "{") {
      depth += 1;
    } else if (char === "}" && --depth === 0) {
      try {
        return JSON.parse(html.slice(open, index + 1)) as YouTubePlayerResponse;
      } catch {
        return null;
      }
    }
  }
  return null;
}

/** Best effort: the captions often need a session the server doesn't have, so failures are ignored. */
async function youTubeTranscript(player: YouTubePlayerResponse): Promise<string | null> {
  const tracks = player.captions?.playerCaptionsTracklistRenderer?.captionTracks ?? [];
  // Prefer captions written by the uploader over auto-generated ones.
  const track = tracks.find((candidate) => candidate.kind !== "asr") ?? tracks[0];
  if (!track?.baseUrl) return null;
  try {
    const captions = await fetchJson(`${track.baseUrl}&fmt=json3`) as { events?: { segs?: { utf8?: string }[] }[] };
    const text = (captions.events ?? [])
      .map((event) => (event.segs ?? []).map((segment) => segment.utf8 ?? "").join(""))
      .join(" ");
    return normalizeWhitespace(text) || null;
  } catch {
    return null;
  }
}

/** Title, channel, description and (when available) the transcript of a video. */
async function extractYouTubeVideo(url: string): Promise<PlatformExtraction | null> {
  const id = youTubeVideoId(url);
  if (!id) return null;
  const page = await fetchPublicDocument(`https://www.youtube.com/watch?v=${id}&hl=en`);
  const player = playerResponseFrom(decodeText(page.bytes, page.charset));
  const details = player?.videoDetails;
  if (!player || !details?.title) return null;
  const transcript = await youTubeTranscript(player);
  const sections = [
    `Video: ${details.title}`,
    details.author ? `Channel: ${details.author}` : null,
    details.shortDescription?.trim() ? `Description:\n${details.shortDescription.trim()}` : null,
    transcript ? `Transcript:\n${transcript}` : null,
  ];
  const thumbnails = details.thumbnail?.thumbnails ?? [];
  return {
    text: normalizeWhitespace(sections.filter(Boolean).join("\n\n")),
    title: details.title,
    siteName: "YouTube",
    imageUrl: thumbnails[thumbnails.length - 1]?.url ?? null,
  };
}
