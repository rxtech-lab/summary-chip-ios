/** Trusted runner installed per render, outside agent-controlled src/. No account credentials. */
export const CLOUD_RENDER_RUNNER = String.raw`
import { bundle } from '@remotion/bundler';
import { renderMedia, selectComposition } from '@remotion/renderer';
import { writeFile, rename } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
const resolution = Number(process.argv[2]);
const maxSeconds = Number(process.argv[3] || 0);
const language = process.argv[4] || 'und';
const languageCodes = { en: 'eng', zh: 'zho', ja: 'jpn', ko: 'kor', es: 'spa', fr: 'fra', de: 'deu', it: 'ita', pt: 'por', ru: 'rus', ar: 'ara' };
const subtitleLanguage = languageCodes[language.toLowerCase().split(/[-_]/)[0]] || 'und';
async function status(value) {
  await writeFile('status.tmp', JSON.stringify(value));
  await rename('status.tmp', 'status.json');
}
try {
  const serveUrl = await bundle({entryPoint: process.cwd() + '/src/index.ts', publicDir: process.cwd() + '/public'});
  const composition = await selectComposition({serveUrl, id: 'Main'});
  if (maxSeconds > 0 && composition.durationInFrames / composition.fps > maxSeconds) throw new Error('Recap exceeds duration limit');
  await renderMedia({serveUrl, composition, codec: 'h264', outputLocation: 'silent-captions.mp4',
    scale: resolution / composition.height, concurrency: 2,
  });
  // Preserve the recording mixed by Remotion and add selectable captions, including CJK text.
  execFileSync('ffmpeg', ['-y', '-i', 'silent-captions.mp4', '-i', 'captions.srt',
    '-map', '0:v:0', '-map', '0:a:0', '-map', '1:0', '-c:v', 'copy', '-c:a', 'copy',
    '-c:s', 'mov_text', '-metadata:s:s:0', 'language=' + subtitleLanguage,
    '-movflags', '+faststart', 'render.mp4']);
  const info = JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', 'render.mp4']).toString());
  const video = info.streams.find(s => s.codec_type === 'video');
  if (!video || video.height !== resolution || video.width !== resolution * 16 / 9 ||
      !info.streams.some(s => s.codec_type === 'audio') || !info.streams.some(s => s.codec_type === 'subtitle' && s.tags?.language === subtitleLanguage) ||
      Number(info.format.duration) <= 0 || (maxSeconds > 0 && Number(info.format.duration) > maxSeconds) || Math.abs(Number(info.format.duration) - composition.durationInFrames / composition.fps) > 2)
    throw new Error('Invalid output');
  // Decode a frame as well as probing metadata before making the file downloadable.
  execFileSync('ffmpeg', ['-v', 'error', '-i', 'render.mp4', '-frames:v', '1', '-f', 'null', '-']);
  await status({status: 'ready', byteSize: Number(info.format.size)});
} catch {
  await status({status: 'failed'});
  process.exitCode = 1;
}
`;
