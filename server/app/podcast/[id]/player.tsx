"use client";

import { captionText } from "@/lib/services/podcast-captions";
import { useRef, useState } from "react";
import { usePathname, useRouter } from "next/navigation";
import type { publicPodcastData } from "@/lib/services/podcast-sharing";

export default function PodcastWebPlayer({ podcast }: { podcast: Awaited<ReturnType<typeof publicPodcastData>> }) {
  // A published motion video carries its own captions and the recording; otherwise play audio over the artwork.
  const audio = useRef<HTMLMediaElement>(null);
  const [time, setTime] = useState(0);
  const [error, setError] = useState(false);
  const router = useRouter();
  const pathname = usePathname();
  const languageNames = new Intl.DisplayNames([podcast.language], { type: "language" });
  const segment = podcast.segments.find(s => s.startSeconds <= time && time < s.endSeconds);
  const caption = segment?.captionCues
    ? segment.captionCues.find(cue => cue.startSeconds <= time && time < cue.endSeconds)?.text ?? ""
    : captionText(segment?.caption ?? "");
  return <article className={`grid items-start gap-8 lg:gap-12 ${podcast.article ? "lg:grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)]" : "mx-auto w-full max-w-3xl"}`} lang={podcast.language}>
    <div className="min-w-0 space-y-5 lg:sticky lg:top-6">
    {podcast.videoPath ? <video ref={audio as React.RefObject<HTMLVideoElement>} controls playsInline preload="metadata" src={podcast.videoPath}
      className="aspect-video w-full rounded-3xl bg-black" aria-label={podcast.title}
      onTimeUpdate={event => setTime(event.currentTarget.currentTime)} onError={() => setError(true)} /> : <div className="relative flex aspect-video items-center justify-center overflow-hidden rounded-3xl bg-indigo-950 text-7xl">
      <span aria-hidden>{segment?.icon ?? "🎙️"}</span>
      {(segment?.imagePath ?? podcast.coverPath) && <div aria-hidden className="absolute inset-0 bg-cover bg-center" style={{ backgroundImage: `url(${segment?.imagePath ?? podcast.coverPath})` }} />}
      {segment && <div className="absolute inset-x-3 bottom-3 max-h-[65%] overflow-y-auto rounded-2xl bg-black/70 p-4 text-base text-white backdrop-blur-md">
        <p className="mb-1 text-xs text-white/70">{segment.speaker}</p>
        <p>{caption}</p>
      </div>}
    </div>}
    <div className="flex flex-wrap items-center justify-between gap-3">
      <h1 className="text-2xl font-bold">{podcast.title}</h1>
      {podcast.languages.length > 1 && <label className="flex items-center gap-2 text-sm">
        <span className="opacity-60">Language</span>
        <select value={podcast.language} className="rounded-xl border border-current/20 bg-transparent px-3 py-2"
          onChange={event => router.replace(event.target.value === podcast.languages[0] ? pathname : `${pathname}?language=${encodeURIComponent(event.target.value)}`)}>
          {podcast.languages.map(code => <option key={code} value={code}>{languageNames.of(code) ?? code}</option>)}
        </select>
      </label>}
    </div>
    {!podcast.videoPath && <audio ref={audio as React.RefObject<HTMLAudioElement>} controls preload="metadata" src={podcast.audioPath} className="w-full"
      aria-label={podcast.title} onTimeUpdate={event => setTime(event.currentTarget.currentTime)} onError={() => setError(true)} />}
    </div>
    {error && <div role="alert" className="fixed inset-x-5 top-5 mx-auto max-w-lg rounded-2xl bg-neutral-900 p-4 text-white shadow-xl">
      {podcast.videoPath ? "Video" : "Audio"} unavailable. This link may have expired or been made private.
    </div>}
    {podcast.article && <section className="min-w-0 space-y-8 border-t border-current/15 pt-8 lg:border-t-0 lg:pt-0" aria-label="About this episode">
      <p className="text-lg leading-relaxed opacity-75">{podcast.article.description}</p>
      {podcast.article.sections.map((section, index) => <section key={index} className="space-y-3">
        <div className="flex items-baseline justify-between gap-4">
          <h2 className="text-xl font-semibold">{section.heading}</h2>
          <button className="shrink-0 rounded-full border border-current/20 px-3 py-1 font-mono text-sm hover:bg-current/5"
            aria-label={`Jump to ${timestamp(section.startSeconds)}: ${section.heading}`}
            onClick={() => {
              if (audio.current) {
                audio.current.currentTime = section.startSeconds;
                setTime(section.startSeconds);
                void audio.current.play().catch(() => setError(true));
                if (!window.matchMedia("(min-width: 1024px)").matches) {
                  audio.current.scrollIntoView({ behavior: "smooth", block: "center" });
                }
              }
            }}>{timestamp(section.startSeconds)}</button>
        </div>
        {section.paragraphs.map((paragraph, i) => <p key={i} className="leading-relaxed opacity-85">{paragraph}</p>)}
      </section>)}
      <p className="text-xs opacity-50">Article written with AI from this episode.</p>
    </section>}

  </article>;
}

function timestamp(seconds: number) {
  const value = Math.max(0, Math.floor(seconds));
  return `${Math.floor(value / 60)}:${String(value % 60).padStart(2, "0")}`;
}
