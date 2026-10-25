import type { PodcastDay } from "./daily-podcast";

/** Owner-only job history. Logs contain tool activity, never model messages or source text. */
export interface BackgroundJob {
  id: string;
  title: string;
  episodeKey: string;
  day: PodcastDay;
  language?: string;
  status: "running" | "ready" | "failed";
  percent: number;
  /** Safe, actionable failure details; never a provider response body or prompt. */
  error?: { code: string; message: string };
  /** Exact composition produced by this run; older jobs must not render a replacement. */
  videoId?: string;
  createdAt: string;
  updatedAt: string;
  logs: { id: string; at: string; message: string }[];
}
