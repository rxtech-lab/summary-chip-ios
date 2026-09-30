import { after } from "next/server";

/** Schedules work after the response via `after()`, or fires it immediately outside a request scope (tests). */
export function runAfter(task: () => Promise<unknown>): void {
  const safe = () => task().catch((error) => console.warn("[after] background task failed", error));
  try {
    after(safe);
  } catch {
    void safe();
  }
}
