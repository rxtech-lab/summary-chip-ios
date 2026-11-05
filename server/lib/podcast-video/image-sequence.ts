import type { AudiobookSceneMotion, DailyPodcast, PodcastVideoSource } from "@/lib/contracts/daily-podcast";

const FPS = 24;
/** Keeps a long book's MP4 under the upload limit: the budget left after audio, shared across its length. */
const MAX_BYTES = 950 * 1024 * 1024;
const AUDIO_KBPS = 128;

type Scene = NonNullable<PodcastVideoSource["imageSequence"]>["scenes"][number];

/** FFmpeg's zoompan for one move. Stills are scaled up first, or the slow drift steps from pixel to pixel. */
export function zoompanFilter(motion: AudiobookSceneMotion, frames: number, width: number, height: number) {
  const center = "x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'";
  const progress = `(on/${Math.max(1, frames - 1)})`;
  const moves: Record<AudiobookSceneMotion, string> = {
    "zoom-in": `z='1+0.12*${progress}':${center}`,
    "zoom-out": `z='1.12-0.12*${progress}':${center}`,
    "pan-left": `z='1.12':x='(iw-iw/zoom)*(1-${progress})':y='ih/2-(ih/zoom/2)'`,
    "pan-right": `z='1.12':x='(iw-iw/zoom)*${progress}':y='ih/2-(ih/zoom/2)'`,
    "pan-up": `z='1.12':x='iw/2-(iw/zoom/2)':y='(ih-ih/zoom)*(1-${progress})'`,
    "pan-down": `z='1.12':x='iw/2-(iw/zoom/2)':y='(ih-ih/zoom)*${progress}'`,
  };
  const seconds = frames / FPS;
  const fade = Math.min(0.4, seconds / 3);
  return `scale=${width * 3 / 2}:-2,zoompan=${moves[motion]}:d=${frames}:s=${width}x${height}:fps=${FPS},fade=t=in:st=0:d=${fade},fade=t=out:st=${Math.max(0, seconds - fade).toFixed(3)}:d=${fade},format=yuv420p`;
}

/** Each scene's frames, cut at whole frames from the running total so the picture never drifts from the voice. */
export function imageSequenceManifest(podcast: Pick<DailyPodcast, "segments" | "durationSeconds">, scenes: Scene[], resolution: 720 | 1080) {
  const duration = podcast.durationSeconds ?? 0;
  const width = resolution * 16 / 9;
  const startOf = (scene: Scene, index: number) => index === 0 ? 0 : podcast.segments[scene.segment]?.startSeconds ?? 0;
  const paths = new Map<string, string>();
  const clips = scenes.flatMap((scene, index) => {
    const start = Math.round(startOf(scene, index) * FPS);
    const next = scenes[index + 1];
    const end = Math.round((next ? startOf(next, index + 1) : duration) * FPS);
    if (end <= start) return [];
    if (!paths.has(scene.file)) paths.set(scene.file, `image-${paths.size}.png`);
    return [{ image: paths.get(scene.file)!, frames: end - start, filter: zoompanFilter(scene.motion, end - start, width, resolution) }];
  });
  const videoKbps = Math.floor(Math.min(2500, MAX_BYTES * 8 / 1000 / Math.max(1, duration) - AUDIO_KBPS));
  return { fps: FPS, width, height: resolution, duration, videoKbps: Math.max(150, videoKbps), audioKbps: AUDIO_KBPS, clips,
    images: [...paths].map(([file, path]) => ({ file, path })) };
}

/** MP4 chapter markers in FFmpeg's metadata format, so players can jump between chapters of the video too. */
export function chapterMetadata(podcast: Pick<DailyPodcast, "chapters" | "title">) {
  const escape = (text: string) => text.replace(/[=;#\\\n]/g, character => `\\${character}`);
  return `;FFMETADATA1\ntitle=${escape(podcast.title)}\n` + (podcast.chapters ?? []).map(chapter =>
    `[CHAPTER]\nTIMEBASE=1/1000\nSTART=${Math.round(chapter.startSeconds * 1000)}\nEND=${Math.round(chapter.endSeconds * 1000)}\ntitle=${escape(chapter.title)}\n`).join("");
}

/** Trusted runner written per render: fetches the scenes, renders one clip per scene, joins them with the recording. */
export const IMAGE_SEQUENCE_RUNNER = String.raw`
import { readFileSync, writeFileSync, renameSync } from 'node:fs';
import { execFile, execFileSync } from 'node:child_process';
import { promisify } from 'node:util';
const run = promisify(execFile);
const manifest = JSON.parse(readFileSync('manifest.json', 'utf8'));
const languageCodes = { en: 'eng', zh: 'zho', ja: 'jpn', ko: 'kor', es: 'spa', fr: 'fra', de: 'deu' };
const subtitleLanguage = languageCodes[String(manifest.language).toLowerCase().split(/[-_]/)[0]] || 'und';
function status(value) { writeFileSync('status.tmp', JSON.stringify(value)); renameSync('status.tmp', 'status.json'); }
async function pool(items, size, work) {
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(size, items.length) }, async () => {
    for (let index = next++; index < items.length; index = next++) await work(items[index], index);
  }));
}
try {
  status({ status: 'running', percent: 1 });
  await pool(manifest.downloads, 8, ({ path, url }) => run('curl', ['--fail', '--silent', '--show-error', '--retry', '3', '--max-time', '900', '-o', path, url]));
  status({ status: 'running', percent: 3 });
  const total = manifest.clips.reduce((sum, clip) => sum + clip.frames, 0);
  let done = 0;
  await pool(manifest.clips, 4, async (clip, index) => {
    await run('ffmpeg', ['-v', 'error', '-y', '-i', clip.image, '-vf', clip.filter, '-frames:v', String(clip.frames), '-r', String(manifest.fps),
      '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '26', '-maxrate', manifest.videoKbps + 'k', '-bufsize', (manifest.videoKbps * 2) + 'k',
      '-threads', '1', '-an', 'clip-' + index + '.mp4'], { maxBuffer: 1 << 24 });
    done += clip.frames;
    status({ status: 'running', percent: 3 + Math.floor(92 * done / total) });
  });
  writeFileSync('clips.txt', manifest.clips.map((_, index) => "file 'clip-" + index + ".mp4'").join('\n'));
  execFileSync('ffmpeg', ['-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', 'clips.txt', '-i', 'podcast.mp3', '-i', 'captions.srt', '-f', 'ffmetadata', '-i', 'chapters.txt',
    '-map', '0:v:0', '-map', '1:a:0', '-map', '2:0', '-map_metadata', '3', '-map_chapters', '3',
    '-c:v', 'copy', '-c:a', 'aac', '-b:a', manifest.audioKbps + 'k', '-c:s', 'mov_text', '-metadata:s:s:0', 'language=' + subtitleLanguage,
    '-movflags', '+faststart', 'render.mp4']);
  const info = JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', 'render.mp4'], { maxBuffer: 1 << 26 }).toString());
  const video = info.streams.find(s => s.codec_type === 'video');
  if (!video || video.height !== manifest.height || video.width !== manifest.width ||
      !info.streams.some(s => s.codec_type === 'audio') || !info.streams.some(s => s.codec_type === 'subtitle' && s.tags?.language === subtitleLanguage) ||
      Math.abs(Number(info.format.duration) - manifest.duration) > 3) throw new Error('Invalid output');
  execFileSync('ffmpeg', ['-v', 'error', '-i', 'render.mp4', '-frames:v', '1', '-f', 'null', '-']);
  status({ status: 'ready', byteSize: Number(info.format.size) });
} catch (error) {
  console.error(error);
  status({ status: 'failed' });
  process.exitCode = 1;
}
`;
