import { afterEach, describe, expect, it, vi } from "vitest";
import { videoProgressObserver, estimateVideoProgress } from "@/lib/ai/podcast-progress";
import { createGateway } from "@ai-sdk/gateway";
import { podcastStream } from "@/lib/http/podcast-stream";
import type { DailyPodcast } from "@/lib/contracts/daily-podcast";

afterEach(() => vi.useRealTimers());
describe("video progress observation", () => {
  it("throttles calls, bounds evidence, and keeps percentages monotonic and below completion", async () => {
    vi.useFakeTimers();
    const decide = vi.fn().mockResolvedValueOnce(75).mockResolvedValueOnce(25).mockResolvedValueOnce(100);
    const report = vi.fn();
    const observer = videoProgressObserver("goal", report, undefined, decide);
    observer.observe("x".repeat(20000));
    observer.observe("more");
    await vi.advanceTimersByTimeAsync(3000);
    observer.observe("repair", "validation failed");
    await vi.advanceTimersByTimeAsync(3000);
    observer.observe("candidate");
    await vi.advanceTimersByTimeAsync(1);
    expect(decide).toHaveBeenCalledTimes(3);
    expect(JSON.parse(decide.mock.calls[0][0]).recentOutput).toHaveLength(12000);
    expect(report.mock.calls.map(([n]) => n)).toEqual([75, 75, 90]);
    observer.stop();
  });
  it("ignores a pending decision after stop and absorbs evaluator failure", async () => {
    let resolve!: (value: number) => void;
    const report = vi.fn();
    const observer = videoProgressObserver("goal", report, undefined, () => new Promise<number>(r => { resolve = r; }));
    observer.observe("writing");
    observer.stop(); resolve(90);
    await Promise.resolve();
    expect(report).not.toHaveBeenCalled();
    const failed = videoProgressObserver("goal", report, undefined, async () => { throw new Error("unavailable"); });
    failed.observe("writing");
    await new Promise(r => setTimeout(r, 0));
    expect(report).not.toHaveBeenCalled(); failed.stop();
  });
});
describe.skipIf(!process.env.PODCAST_SIMULATION_URL)("decision HTTP to client SSE", () => {
  it("evaluates real SDK HTTP and delivers the estimate before completion", async () => {
    const gateway = createGateway({ baseURL: process.env.PODCAST_SIMULATION_URL, apiKey: "local-fixture-only" });
    const response = podcastStream(async report => {
      const percent = await estimateVideoProgress("Scene implementation in progress", AbortSignal.timeout(4000), gateway.evaluationModel("typesafe-ai/jev"));
      expect(percent).toBe(50);
      report({ stage: "video-design", percent: percent! });
      return { key: "fixture" } as DailyPodcast;
    }, "fixture");
    const events = (await response.text()).split("\n\n").filter(s => s.startsWith("data: ")).map(s => JSON.parse(s.slice(6)));
    expect(events.map(e => e.type)).toEqual(["progress", "complete"]);
    expect(events[0].progress).toEqual({ stage: "video-design", percent: 50 });
  });
});
