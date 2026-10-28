import type { PodcastVideoAsset } from "@/lib/contracts/daily-podcast";

/** Folder under public/ for the video agent's generated cut-outs. */
export const PODCAST_VIDEO_IMAGE_DIR = "gen";
/** Images one design run may draw, replacements included. */
export const MAX_PODCAST_VIDEO_IMAGES = 6;
/** A generated cut-out's path under public/. */
export const PODCAST_VIDEO_IMAGE_PATTERN = /^gen\/[a-z0-9][a-z0-9-]{0,39}\.png$/;

export function podcastVideoImagePath(name: string) {
  return `${PODCAST_VIDEO_IMAGE_DIR}/${name}.png`;
}

/** The episode-relative object of a cut-out drawn by design run `runId`. */
export function podcastVideoImageFile(runId: string, path: string) {
  return `video-assets/${runId}/${path.slice(PODCAST_VIDEO_IMAGE_DIR.length + 1)}`;
}

/** Generated image paths the composition's files mention, e.g. `staticFile("gen/rocket.png")`. */
export function referencedPodcastImages(files: Record<string, string>): string[] {
  const paths = new Set<string>();
  for (const source of Object.values(files)) {
    for (const match of source.matchAll(/["'`]\/?(gen\/[^"'`]+)["'`]/g)) paths.add(match[1]);
  }
  return [...paths];
}

/** The composition's assets: the saved cut-outs its files actually use. */
export function podcastVideoAssets(files: Record<string, string>, images: Record<string, { file: string; width: number; height: number }> = {}): PodcastVideoAsset[] {
  return referencedPodcastImages(files).flatMap((path) => {
    const image = images[path];
    return image && PODCAST_VIDEO_IMAGE_PATTERN.test(path) ? [{ path, file: image.file, width: image.width, height: image.height }] : [];
  });
}

/** Whether a stored asset is safe to write under public/ and read from the episode's folder. */
export function isPodcastVideoAsset(asset: PodcastVideoAsset) {
  return PODCAST_VIDEO_IMAGE_PATTERN.test(asset.path) && /^video-assets\/[A-Za-z0-9-]+\/[a-z0-9][a-z0-9-]{0,39}\.png$/.test(asset.file);
}
