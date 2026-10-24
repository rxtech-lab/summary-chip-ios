import type { DailyPodcast, PodcastGenerationEvent, PodcastProgress } from "@/lib/contracts/daily-podcast";
import { errorResponse } from "./errors";

/** One generation per POST. Disconnecting stops delivery, never retries the paid operation. */
export function podcastStream(run: (report: (progress: PodcastProgress) => void) => Promise<DailyPodcast>, requestId: string) {
  let connected = true;
  let heartbeat: ReturnType<typeof setInterval> | undefined;
  const encoder = new TextEncoder();
  const body = new ReadableStream<Uint8Array>({
    async start(controller) {
      const write = (text: string) => { if (connected) controller.enqueue(encoder.encode(text)); };
      const emit = (event: PodcastGenerationEvent) => write(`data: ${JSON.stringify(event)}\n\n`);
      heartbeat = setInterval(() => write(": keepalive\n\n"), 10_000);
      try {
        const podcast = await run((progress) => emit({ type: "progress", progress }));
        emit({ type: "complete", podcast });
      } catch (error) {
        const response = errorResponse(error, requestId);
        const envelope = await response.json();
        emit({ type: "error", status: response.status, error: envelope.error });
      } finally {
        clearInterval(heartbeat);
        if (connected) { connected = false; controller.close(); }
      }
    },
    cancel() { connected = false; clearInterval(heartbeat); },
  });
  return new Response(body, { headers: {
    "content-type": "text/event-stream; charset=utf-8",
    "cache-control": "private, no-store, no-transform",
    "x-accel-buffering": "no",
  } });
}
