"use client";

import { captionText } from "@/lib/services/podcast-captions";
import { useRef, useState } from "react";
import type { publicPodcastData } from "@/lib/services/podcast-sharing";

export default function PodcastWebPlayer({ podcast }: { podcast: Awaited<ReturnType<typeof publicPodcastData>> }) {
  // A published motion video carries its own captions and the recording; otherwise play audio over the artwork.
  const audio = useRef<HTMLMediaElement>(null);
  const [time, setTime] = useState(0);
  const [error, setError] = useState(false);
  const segment = podcast.segments.find(s => s.startSeconds <= time && time < s.endSeconds);
  const caption = segment?.captionCues
    ? segment.captionCues.find(cue => cue.startSeconds <= time && time < cue.endSeconds)?.text ?? ""
    : captionText(segment?.caption ?? "");
  return <article className="flex flex-col gap-5" lang={podcast.language}>
    {podcast.videoPath ? <video ref={audio as React.RefObject<HTMLVideoElement>} controls playsInline preload="metadata" src={podcast.videoPath}
      className="aspect-video w-full rounded-3xl bg-black" aria-label={podcast.title}
      onTimeUpdate={event => setTime(event.currentTarget.currentTime)} onError={() => setError(true)} /> : <div className="relative flex aspect-video items-center justify-center overflow-hidden rounded-3xl bg-indigo-950 text-7xl">
      <span aria-hidden>{segment?.icon ?? "🎙️"}</span>
      {segment?.imagePath && <div aria-hidden className="absolute inset-0 bg-cover bg-center" style={{ backgroundImage: `url(${segment.imagePath})` }} />}
      {segment && <div className="absolute inset-x-3 bottom-3 max-h-[65%] overflow-y-auto rounded-2xl bg-black/70 p-4 text-base text-white backdrop-blur-md">
        <p className="mb-1 text-xs text-white/70">{segment.speaker}</p>
        <p>{caption}</p>
      </div>}
    </div>}
    <h1 className="text-2xl font-bold">{podcast.title}</h1>
    {!podcast.videoPath && <audio ref={audio as React.RefObject<HTMLAudioElement>} controls preload="metadata" src={podcast.audioPath} className="w-full"
      aria-label={podcast.title} onTimeUpdate={event => setTime(event.currentTarget.currentTime)} onError={() => setError(true)} />}
    {error && <div role="alert" className="fixed inset-x-5 top-5 mx-auto max-w-lg rounded-2xl bg-neutral-900 p-4 text-white shadow-xl">
      {podcast.videoPath ? "Video" : "Audio"} unavailable. This link may have expired or been made private.
    </div>}
    <details className="rounded-2xl border border-current/15 p-5">
      <summary className="cursor-pointer font-semibold">Transcript</summary>
      <ol className="mt-4 space-y-4">
        {podcast.segments.map((turn, index) => <li key={index}>
          <button className="text-left underline-offset-4 hover:underline" onClick={() => {
            if (audio.current) { audio.current.currentTime = turn.startSeconds; setTime(turn.startSeconds); }
          }} aria-label={`Seek to ${Math.floor(turn.startSeconds)} seconds: ${turn.speaker}`}>
            <span className="mr-2 font-semibold">{turn.speaker}</span>{turn.caption}
          </button>
        </li>)}
      </ol>
    </details>
  </article>;
}
