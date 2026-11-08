import { randomUUID } from "node:crypto";
import type { PodcastPlanMessage } from "@/lib/contracts/daily-podcast";

/** Chat entries kept on a plan. */
export const MAX_PLAN_MESSAGES = 60;
/** Plan entries that keep their snapshot; older ones stay as placeholders so the transcript stays small. */
export const MAX_PLAN_SNAPSHOTS = 8;

/** The chat as the planning model reads it: shown plans are represented by the current plan instead. */
export function planChatHistory(messages: PodcastPlanMessage[]) {
  return messages.filter(message => message.kind !== "plan" && message.text.trim()).map(({ role, text }) => ({ role, text }));
}

/**
 * Adds one chat turn to a plan's transcript.
 *
 * The plan the user was reviewing stays where it was shown, frozen as it was when they wrote (it may have been
 * edited by hand since it was shown), so it reads above their message. A revised plan the agent chose to show is
 * added below their message as a new entry, followed by the agent's reply; the app keeps only the newest plan
 * entry editable.
 */
export function appendPlanTurn(messages: PodcastPlanMessage[], turn: {
  current: unknown;
  revision: number;
  request: string;
  reply: string;
  /** The revised plan the agent showed; null when it only answered. */
  shown: unknown | null;
  now: string;
}): PodcastPlanMessage[] {
  const next = [...messages];
  const snapshot = (plan: unknown, revision: number): PodcastPlanMessage =>
    ({ id: randomUUID(), role: "assistant", kind: "plan", text: "", plan, revision, createdAt: turn.now });
  const last = next.findLastIndex(message => message.kind === "plan");
  // Before any plan entry the app shows the first plan above the chat, so that's where its snapshot goes.
  if (last < 0) next.unshift(snapshot(turn.current, turn.revision));
  else next[last] = { ...next[last], plan: turn.current, revision: turn.revision };
  next.push({ id: randomUUID(), role: "user", kind: "text", text: turn.request, revision: turn.revision, createdAt: turn.now });
  const revision = turn.shown ? turn.revision + 1 : turn.revision;
  if (turn.shown) next.push(snapshot(turn.shown, revision));
  next.push({ id: randomUUID(), role: "assistant", kind: "text", text: turn.reply, revision, createdAt: turn.now });
  const kept = next.slice(-MAX_PLAN_MESSAGES);
  let snapshots = 0;
  for (let index = kept.length - 1; index >= 0; index -= 1) {
    if (kept[index].kind !== "plan") continue;
    snapshots += 1;
    if (snapshots > MAX_PLAN_SNAPSHOTS && kept[index].plan !== undefined) {
      const { plan: _dropped, ...placeholder } = kept[index];
      kept[index] = placeholder;
    }
  }
  return kept;
}
