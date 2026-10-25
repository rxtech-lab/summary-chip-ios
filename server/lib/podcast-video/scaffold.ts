import { build, type Plugin } from "esbuild";
import ts from "typescript";
import path from "node:path";

/** Frames per second and size of every podcast motion video; the app renders at these settings on device. */
export const PODCAST_VIDEO_FPS = 24;
export const PODCAST_VIDEO_WIDTH = 1280;
export const PODCAST_VIDEO_HEIGHT = 720;

/** The only bare imports the agent may use; all are bundled into the app's renderer. */
export const PODCAST_VIDEO_IMPORTS = ["react", "react/jsx-runtime", "remotion"] as const;
/** Files the agent writes. `src/Video.tsx` must export `PodcastVideo`. */
export const PODCAST_VIDEO_ENTRY = "src/Video.tsx";
export const PODCAST_VIDEO_FILE_PATTERN = /^src\/(?:[A-Za-z0-9_-]+\/)*[A-Za-z0-9_-]+\.(?:tsx|ts|css)$/;
export const MAX_PODCAST_VIDEO_FILES = 8;
export const MAX_PODCAST_VIDEO_FILE_CHARS = 60_000;

/**
 * Types and helpers every composition shares. The app writes `src/data.json` with the episode's real
 * timings, artwork file names and chip titles, so the same source plays any recording of the script.
 */
const PODCAST_TS = `import { useCurrentFrame, useVideoConfig } from "remotion";
import data from "./data.json";
import phraseWindows from "./phrases.json";

export interface PodcastSegment {
  /** Index into \`speakers\`. */
  speaker: number;
  chipId: string;
  /** Title of the chip this turn discusses. */
  chipTitle: string;
  /** The turn's window in the recording, in seconds. Intro music plays before the first; gaps sit between turns. */
  startSeconds: number;
  endSeconds: number;
  /** When the voice is audible inside the turn. */
  voiceStartSeconds: number;
  voiceEndSeconds: number;
  /** Artwork file under public/ for staticFile(), or null: then show \`icon\` (an emoji). */
  image: string | null;
  icon: string;
}
export interface PodcastVideoData {
  title: string;
  /** BCP 47 language of the captions. */
  language: string;
  /** bright, calm, focused, warm or reflective. */
  mood: string;
  durationSeconds: number;
  fps: number;
  width: number;
  height: number;
  speakers: { name: string }[];
  segments: PodcastSegment[];
}

export const podcast = data as PodcastVideoData;

/** The current playback time in seconds. */
export function useTime(): number {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  return frame / fps;
}

export function toFrame(seconds: number): number {
  return Math.round(seconds * podcast.fps);
}

/**
 * The turn being spoken (or the last one before a gap); -1 before the first turn starts.
 * \`progress\` runs 0…1 across the turn's window.
 */
export function useSegment(): { index: number; segment: PodcastSegment | null; progress: number } {
  const time = useTime();
  let index = -1;
  for (let i = 0; i < podcast.segments.length; i += 1) if (podcast.segments[i].startSeconds <= time) index = i;
  const segment = index >= 0 ? podcast.segments[index] : null;
  const progress = segment ? Math.min(1, Math.max(0, (time - segment.startSeconds) / Math.max(0.001, segment.endSeconds - segment.startSeconds))) : 0;
  return { index, segment, progress };
}

/** Continuous topic clock: does not restart on speaker changes or freeze in gaps.
 * loopProgress wraps; use it for a closed path or sin/cos, never a snapping heading.
 */
export function useSceneMotion(periodSeconds = 6): { elapsedSeconds: number; loopProgress: number } {
  const time = useTime();
  const { index, segment } = useSegment();
  let first = index;
  while (first > 0 && podcast.segments[first - 1].chipId === segment?.chipId) first -= 1;
  const start = first >= 0 ? podcast.segments[first].startSeconds : 0;
  const elapsedSeconds = Math.max(0, time - start);
  const period = Number.isFinite(periodSeconds) && periodSeconds > 0 ? periodSeconds : 6;
  return { elapsedSeconds, loopProgress: (elapsedSeconds % period) / period };
}

/** Select a storyboard turn and advance its explanation only during the voice.
 * Hold the completed explanation in gaps. Timings are per turn, not word aligned.
 */
export function useNarration() {
  const time = useTime();
  const { index, segment } = useSegment();
  const start = segment?.voiceStartSeconds ?? 0;
  const end = segment?.voiceEndSeconds ?? start;
  const duration = Math.max(0, end - start);
  const elapsedSeconds = segment ? Math.min(duration, Math.max(0, time - start)) : 0;
  const progress = segment && time >= end ? 1 : duration > 0 ? elapsedSeconds / duration : 0;
  return { index, segment, elapsedSeconds, progress, speaking: !!segment && time >= start && time < end };
}

/** Each turn's transcribed phrases as [start, end] fractions (0…1) of its voice window, by segment index. */
const phrases = phraseWindows as [number, number][][];

/**
 * useNarration() plus the transcribed phrases of the current turn, so each action lands on the words
 * that describe it. \`phrase\` is the phrase being spoken (held through pauses and after the voice ends).
 * \`at(k)\` runs 0…1 across phrase k while it is spoken: use it for actions that unfold with the sentence.
 * \`cue(k, seconds)\` runs 0…1 over \`seconds\` (default 0.6), starting 0.15 s before phrase k so the
 * picture leads the voice slightly: use it for entrances, highlights and state changes.
 * Both are 0 before the phrase and hold 1 afterwards; k is clamped to the turn's phrases.
 */
export function usePhrases() {
  const narration = useNarration();
  const time = useTime();
  const windows = (narration.index >= 0 ? phrases[narration.index] : undefined) ?? [];
  const list: [number, number][] = windows.length ? windows : [[0, 1]];
  const start = narration.segment?.voiceStartSeconds ?? 0;
  const duration = Math.max(0.001, (narration.segment?.voiceEndSeconds ?? start) - start);
  const range = (k: number) => list[Math.max(0, Math.min(list.length - 1, Math.floor(k)))];
  const clamp = (value: number) => Math.min(1, Math.max(0, value));
  let phrase = 0;
  for (let i = 0; i < list.length; i += 1) if (list[i][0] <= narration.progress) phrase = i;
  const at = (k: number) => {
    const [from, to] = range(k);
    return clamp((narration.progress - from) / Math.max(0.001, to - from));
  };
  const cue = (k: number, seconds = 0.6) => narration.segment
    ? clamp((time - (start + range(k)[0] * duration - 0.15)) / Math.max(0.05, seconds)) : 0;
  return { ...narration, phrase, phraseCount: list.length, phraseProgress: at(phrase), at, cue };
}

/** Turn indexes where the story (chip) changes. A chip discussed again later starts a new story. */
const storyStarts = podcast.segments.flatMap((segment, i) => (i > 0 && segment.chipId !== podcast.segments[i - 1].chipId ? [i] : []));

/**
 * The bridge between two stories: it starts when the outgoing story's voice ends and finishes when the
 * incoming voice begins, lasting at least \`minSeconds\` and at most \`maxSeconds\` (it may then start later).
 * \`progress\` is 0 before the bridge, runs 0…1 across it and holds 1 afterwards. While \`active\`, the
 * turn from useNarration() can still be the outgoing one: draw \`from\` leaving and \`to\` arriving yourself.
 * \`story\` counts stories from 0, \`storyCount\` is their total, and \`transition\` is the bridge index (-1 before the first).
 */
export function useStoryTransition(minSeconds = 0.9, maxSeconds = 1.6) {
  const time = useTime();
  const bridge = (i: number) => {
    const before = podcast.segments[i - 1];
    const after = podcast.segments[i];
    const start = Math.max(before.voiceEndSeconds, after.voiceStartSeconds - maxSeconds);
    return { start, end: Math.max(start + minSeconds, after.voiceStartSeconds) };
  };
  let current = -1;
  for (let b = 0; b < storyStarts.length; b += 1) if (bridge(storyStarts[b]).start <= time) current = b;
  if (current < 0) {
    return { active: false, progress: 1, from: null, to: podcast.segments[0] ?? null, story: 0, storyCount: storyStarts.length + 1, transition: -1 };
  }
  const i = storyStarts[current];
  const { start, end } = bridge(i);
  const progress = Math.min(1, Math.max(0, (time - start) / Math.max(0.001, end - start)));
  return { active: progress > 0 && progress < 1, progress, from: podcast.segments[i - 1], to: podcast.segments[i],
    story: current + 1, storyCount: storyStarts.length + 1, transition: current };
}
`;

const ROOT_TSX = `import { Audio, Composition, staticFile } from "remotion";
import { podcast } from "./podcast";
import { PodcastVideo } from "./Video";

/** The app puts the recording at public/podcast.mp3; the renderer mixes it into the movie. */
const Episode: React.FC = () => (
  <>
    <PodcastVideo />
    <Audio src={staticFile("podcast.mp3")} />
  </>
);

export const RemotionRoot: React.FC = () => (
  <Composition id="Main" component={Episode}
    durationInFrames={Math.max(1, Math.ceil(podcast.durationSeconds * podcast.fps))}
    fps={podcast.fps} width={podcast.width} height={podcast.height} />
);
`;

const INDEX_TS = `import { registerRoot } from "remotion";
import { RemotionRoot } from "./Root";

registerRoot(RemotionRoot);
`;

/** Transcribed phrase timing written by the server next to the composition (see `podcastPhraseWindows`). */
export const PODCAST_VIDEO_PHRASES = "src/phrases.json";

/** Files owned by the server; the agent can't replace them. */
export const PODCAST_VIDEO_SCAFFOLD: Readonly<Record<string, string>> = {
  "src/index.ts": INDEX_TS,
  "src/Root.tsx": ROOT_TSX,
  "src/podcast.ts": PODCAST_TS,
};

/** The scaffold's data types, shown to the agent. */
export const PODCAST_VIDEO_HELPERS = PODCAST_TS;

/** Representative data so validation bundles exactly what the app compiles. */
const SAMPLE_DATA = {
  title: "Sample", language: "en", mood: "calm", durationSeconds: 30, fps: PODCAST_VIDEO_FPS,
  width: PODCAST_VIDEO_WIDTH, height: PODCAST_VIDEO_HEIGHT, speakers: [{ name: "Alex" }],
  segments: [{ speaker: 0, chipId: "a", chipTitle: "Sample", caption: "Hello.", startSeconds: 5, endSeconds: 9,
    voiceStartSeconds: 5.1, voiceEndSeconds: 8.8, image: null, icon: "🎙️" }],
};
const SAMPLE_PHRASES = [[[0, 0.5], [0.5, 1]]];

/** A turn's transcribed phrases, as the device sees them in `src/phrases.json`. */
export interface PodcastPhraseTiming { startSeconds: number; endSeconds: number }

/**
 * Each turn's phrases as [start, end] fractions of its voice window. Fractions, not seconds, so a
 * translation (same turns, different recording) replays the same staging proportionally.
 */
export function podcastPhraseWindows(segments: { voiceStartSeconds: number; voiceEndSeconds: number; phrases: PodcastPhraseTiming[] }[]): [number, number][][] {
  const round = (value: number) => Math.round(Math.min(1, Math.max(0, value)) * 1000) / 1000;
  return segments.map(({ voiceStartSeconds, voiceEndSeconds, phrases }) => {
    const duration = voiceEndSeconds - voiceStartSeconds;
    if (!(duration > 0) || !phrases.length) return [[0, 1]];
    return phrases.map(({ startSeconds, endSeconds }) => [round((startSeconds - voiceStartSeconds) / duration), round((endSeconds - voiceStartSeconds) / duration)]);
  });
}

/**
 * Bundles a project for the browser compiler (validation) or for the frame preview, where the
 * bare imports resolve to `runtime` instead of staying external.
 */
export async function bundlePodcastProject(all: Record<string, string>, entry: string, runtime?: string) {
  const resolveFile = (path: string) => ["", ".tsx", ".ts", ".css", ".json", "/index.tsx", "/index.ts"].map((ext) => path + ext).find((p) => p in all);
  const normalize = (path: string) => {
    const parts: string[] = [];
    for (const part of path.split("/")) {
      if (part === "..") { if (!parts.length) throw new Error("Import escapes the project"); parts.pop(); }
      else if (part && part !== ".") parts.push(part);
    }
    return parts.join("/");
  };
  const project: Plugin = { name: "podcast-project", setup(builder) {
    builder.onResolve({ filter: /.*/ }, (args) => {
      if (args.kind === "entry-point") return { path: args.path, namespace: "project" };
      if ((PODCAST_VIDEO_IMPORTS as readonly string[]).includes(args.path)) {
        return runtime === undefined ? { path: args.path, external: true } : { path: "runtime", namespace: "preview-runtime" };
      }
      if (!args.path.startsWith(".")) return { errors: [{ text: `Unsupported import "${args.path}". Only ${PODCAST_VIDEO_IMPORTS.join(", ")} and project files are available.` }] };
      const path = resolveFile(normalize(`${args.importer.split("/").slice(0, -1).join("/")}/${args.path}`));
      return path ? { path, namespace: "project" } : { errors: [{ text: `Cannot resolve local import: ${args.path}` }] };
    });
    builder.onLoad({ filter: /.*/, namespace: "preview-runtime" }, () => ({ contents: runtime, loader: "js" }));
    builder.onLoad({ filter: /.*/, namespace: "project" }, (args) => {
      const extension = args.path.split(".").pop();
      // The preview can't apply stylesheets; the browser compiler bundles them.
      if (extension === "css" && runtime !== undefined) return { contents: "", loader: "empty" };
      return { contents: all[args.path], loader: ({ ts: "ts", tsx: "tsx", css: "css", json: "json" } as const)[extension as "ts"] ?? "ts" };
    });
  } };
  return build({ entryPoints: [entry], bundle: true, write: false, platform: "browser", jsx: "automatic", outdir: "/out", logLevel: "silent", plugins: [project],
    ...(runtime === undefined ? { format: "esm", target: "safari26" } : { format: "iife", globalName: "__preview", target: "es2020" }) });
}

/** esbuild failures as validation issues. */
export function bundleIssues(error: unknown): PodcastVideoIssue[] {
  const errors = (error as { errors?: { text: string; location?: { file: string; line: number; column: number } | null }[] }).errors;
  if (!errors?.length) return [{ message: error instanceof Error ? error.message : String(error) }];
  return errors.slice(0, 12).map((e) => ({ file: e.location?.file.replace(/^project:/, ""), message: e.location ? `${e.location.line}:${e.location.column} ${e.text}` : e.text }));
}

/**
 * Source the renderer can't run deterministically or safely. Agent code is untrusted: chip content
 * could steer it, so it gets no network, storage, timers or dynamic code, and no raw media (the app
 * adds the recording itself). WebKit snapshots can't capture 3D transforms, blend modes or backdrop filters.
 */
const FORBIDDEN: { pattern: RegExp; message: string }[] = [
  { pattern: /\bMath\s*(?:\.\s*random|\[\s*["']random["']\s*\])|\bcrypto\b/, message: "Random geometry flickers between frames; use remotion random() with a literal seed" },
  { pattern: /\buse(?:State|Reducer|Effect|LayoutEffect)\b/, message: "Frame output must not depend on React state or effects; derive motion directly from frame/time" },
  { pattern: /@keyframes\b|\b(?:animation|transition)(?:[A-Z][A-Za-z]*|-[a-z-]+)?\s*["']?\s*:/, message: "CSS animations and transitions drift during capture; calculate styles from frame/time instead" },
  { pattern: /<\s*(?:animate|animateMotion|animateTransform|set)\b|\.\s*animate\s*\(/, message: "Browser animation timelines are not frame deterministic; animate SVG properties from frame/time" },
  { pattern: /\b(?:useCaption|captionPhrases)\b|\.\s*caption\b|["']caption["']\s*\]/, message: "Subtitles are embedded separately; do not draw narration or captions into video frames" },
  { pattern: /\b(?:fetch|XMLHttpRequest|WebSocket|EventSource|sendBeacon|importScripts)\b/, message: "Network APIs are not available" },
  { pattern: /\bimport\s*\(/, message: "Dynamic import() is not available" },
  { pattern: /\beval\s*\(|\bnew\s+Function\b|\bFunction\s*\(/, message: "Dynamic code is not allowed" },
  { pattern: /\b(?:https?|wss?):\/\//i, message: "Remote URLs are not allowed; use the supplied artwork, CSS and SVG" },
  { pattern: /\b(?:localStorage|sessionStorage|indexedDB|document\.cookie|window\.webkit|postMessage)\b/, message: "Browser storage and messaging are not available" },
  { pattern: /\b(?:setTimeout|setInterval|requestAnimationFrame|Date\.now|performance\.now|new Date)\b/, message: "Animate from useCurrentFrame() only; timers and clocks are not deterministic" },
  { pattern: /<\s*(?:Audio|Html5Audio|Video|OffthreadVideo|Html5Video|IFrame|iframe|audio|video)\b/, message: "Do not add audio, video or iframes; the app adds the recording" },
  { pattern: /backdrop-?filter|mix-?blend-?mode|perspective|preserve-3d|rotate[XY]\s*\(|rotate3d|translate(?:Z|3d)\s*\(|scale(?:Z|3d)\s*\(|matrix3d/i, message: "3D transforms, perspective, blend modes and backdrop filters can't be captured; use 2D transforms" },
  { pattern: /\b(?:dangerouslySetInnerHTML|innerHTML|outerHTML)\b/, message: "Raw HTML injection is not allowed" },
];

export interface PodcastVideoIssue { file?: string; message: string }

/** Checks agent files and bundles them with the scaffold the way the app's browser compiler does. */
export async function validatePodcastVideo(files: Record<string, string>): Promise<PodcastVideoIssue[]> {
  const issues: PodcastVideoIssue[] = [];
  const paths = Object.keys(files);
  if (!paths.includes(PODCAST_VIDEO_ENTRY)) issues.push({ message: `Write ${PODCAST_VIDEO_ENTRY}, exporting PodcastVideo` });
  if (paths.length > MAX_PODCAST_VIDEO_FILES) issues.push({ message: `Use at most ${MAX_PODCAST_VIDEO_FILES} files` });
  for (const [path, source] of Object.entries(files)) {
    if (!PODCAST_VIDEO_FILE_PATTERN.test(path)) issues.push({ file: path, message: "Paths must be src/…/*.tsx, *.ts or *.css" });
    else if (path in PODCAST_VIDEO_SCAFFOLD || path === "src/data.json" || path === PODCAST_VIDEO_PHRASES) issues.push({ file: path, message: "This file is provided; don't write it" });
    if (source.length > MAX_PODCAST_VIDEO_FILE_CHARS) issues.push({ file: path, message: `Keep each file under ${MAX_PODCAST_VIDEO_FILE_CHARS} characters` });
    for (const { pattern, message } of FORBIDDEN) if (pattern.test(source)) issues.push({ file: path, message });
  }
  if (issues.length) return issues;

  const all: Record<string, string> = { ...files, ...PODCAST_VIDEO_SCAFFOLD, "src/data.json": JSON.stringify(SAMPLE_DATA),
    [PODCAST_VIDEO_PHRASES]: JSON.stringify(SAMPLE_PHRASES), "src/__check.ts": `export { PodcastVideo } from "./Video";\nimport "./index";\n` };
  try {
    await bundlePodcastProject(all, "src/__check.ts");
  } catch (error) {
    return bundleIssues(error);
  }
  const nameIssues = unresolvedNames(all, paths);
  if (nameIssues.length) return nameIssues;
  return motionIssues(files);
}

/** A basic authoring gate, not a perceptual motion score. It catches static submissions
 * and changing random seeds before the model's repair loop accepts the source. */
function motionIssues(files: Record<string, string>): PodcastVideoIssue[] {
  const issues: PodcastVideoIssue[] = [];
  let hasClock = false;
  for (const [file, content] of Object.entries(files)) {
    if (!/\.tsx?$/.test(file)) continue;
    const source = ts.createSourceFile(file, content, ts.ScriptTarget.Latest, true, file.endsWith("tsx") ? ts.ScriptKind.TSX : ts.ScriptKind.TS);
    const clocks = new Set<string>();
    const randoms = new Set<string>();
    const namespaces = new Set<string>();
    for (const node of source.statements) {
      if (!ts.isImportDeclaration(node) || !ts.isStringLiteral(node.moduleSpecifier)) continue;
      const moduleName = node.moduleSpecifier.text;
      if (moduleName !== "remotion" && !/(?:^|\/)podcast$/.test(moduleName)) continue;
      const bindings = node.importClause?.namedBindings;
      if (bindings && ts.isNamespaceImport(bindings)) namespaces.add(bindings.name.text);
      if (bindings && ts.isNamedImports(bindings)) for (const binding of bindings.elements) {
        const name = (binding.propertyName ?? binding.name).text;
        if (["useCurrentFrame", "useTime", "useSceneMotion", "useNarration", "usePhrases", "useStoryTransition"].includes(name)) clocks.add(binding.name.text);
        if (moduleName === "remotion" && name === "random") randoms.add(binding.name.text);
      }
    }
    const visit = (node: ts.Node) => {
      if (ts.isCallExpression(node)) {
        const callee = node.expression;
        const member = ts.isPropertyAccessExpression(callee) && ts.isIdentifier(callee.expression) && namespaces.has(callee.expression.text) ? callee.name.text : null;
        if ((ts.isIdentifier(callee) && clocks.has(callee.text)) || (member && ["useCurrentFrame", "useTime", "useSceneMotion", "useNarration", "usePhrases", "useStoryTransition"].includes(member))) hasClock = true;
        if ((ts.isIdentifier(callee) && randoms.has(callee.text)) || member === "random") {
          const seed = node.arguments[0];
          if (!seed || (!ts.isStringLiteral(seed) && !ts.isNumericLiteral(seed))) issues.push({ file, message: "Use a fixed string or number literal random() seed; frame-dependent seeds make shapes and edges flicker" });
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(source);
  }
  if (!hasClock) issues.push({ message: "Static composition: use useSceneMotion(), useTime() or useCurrentFrame() to animate explanatory objects throughout each turn" });
  return issues;
}

/** Bundling strips types but does not check names: `width: W` can bundle and then
 * crash on the device. Check lexical bindings before accepting a paid design.
 * Only name errors are selected; Remotion runtime types are supplied by the app.
 */
function unresolvedNames(files: Record<string, string>, agentPaths: string[]): PodcastVideoIssue[] {
  const root = path.resolve("__podcast_validation__");
  const virtual = new Map(Object.entries(files).map(([name, source]) => [path.join(root, name), source]));
  const options: ts.CompilerOptions = {
    target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.ESNext,
    moduleResolution: ts.ModuleResolutionKind.Bundler, jsx: ts.JsxEmit.ReactJSX,
    resolveJsonModule: true, allowSyntheticDefaultImports: true, noEmit: true,
    skipLibCheck: true, types: [],
  };
  const host = ts.createCompilerHost(options);
  const readFile = host.readFile.bind(host);
  const fileExists = host.fileExists.bind(host);
  const directoryExists = host.directoryExists?.bind(host);
  host.readFile = (name) => virtual.get(name) ?? readFile(name);
  host.fileExists = (name) => virtual.has(name) || fileExists(name);
  host.directoryExists = (name) => name.startsWith(root) || !!directoryExists?.(name);
  host.getSourceFile = (name, languageVersion) => {
    const source = host.readFile(name);
    return source === undefined ? undefined : ts.createSourceFile(name, source, languageVersion, true);
  };
  const program = ts.createProgram([...virtual.keys()].filter((name) => /\.tsx?$/.test(name)), options, host);
  const issues: PodcastVideoIssue[] = [];
  // Missing identifiers, misspelled identifiers and missing shorthand properties.
  const nameErrors = new Set([2304, 2552, 18004]);
  for (const name of agentPaths.filter((name) => /\.tsx?$/.test(name))) {
    const source = program.getSourceFile(path.join(root, name));
    if (!source) continue;
    for (const diagnostic of program.getSemanticDiagnostics(source)) {
      if (!nameErrors.has(diagnostic.code)) continue;
      const position = source.getLineAndCharacterOfPosition(diagnostic.start ?? 0);
      issues.push({ file: name, message: `${position.line + 1}:${position.character + 1} ${ts.flattenDiagnosticMessageText(diagnostic.messageText, " ")}` });
    }
  }
  return issues.slice(0, 12);
}
