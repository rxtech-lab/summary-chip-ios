import { describe, expect, it, vi } from "vitest";
import { compressChatHistory } from "@/lib/ai/chat-context";
import type { ModelMessage } from "ai";

describe("chat context compression", () => {
  it("leaves short histories unchanged", async () => {
    const messages: ModelMessage[] = [{ role: "user", content: "hello" }];
    const summarize = vi.fn();
    expect(await compressChatHistory(messages, {}, summarize)).toBe(messages);
    expect(summarize).not.toHaveBeenCalled();
  });
  it("summarizes in bounded chunks and preserves the latest complete turn", async () => {
    const recent: ModelMessage = { role: "user", content: "next " + "x".repeat(25000) };
    const messages: ModelMessage[] = [{ role: "user", content: "a".repeat(180000) }, { role: "assistant", content: "done" }, recent];
    const summarize = vi.fn(async () => "Previous work summary");
    const result = await compressChatHistory(messages, {}, summarize);
    expect(summarize.mock.calls.length).toBeGreaterThan(1);
    expect(result).toHaveLength(2);
    expect(result[1]).toBe(recent);
  });
});
