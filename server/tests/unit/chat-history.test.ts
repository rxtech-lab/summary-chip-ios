import { describe, expect, it } from "vitest";
import { sanitizeChatMessages } from "@/lib/ai/chat";
const history = [
  { role: "user" as const, parts: [{ type: "text", text: "Find my chips" }] },
  { role: "assistant" as const, parts: [{ type: "text", text: "Here are your chips." }] },
];
describe("voice conversation history", () => {
  it("preserves the final assistant response when resuming voice", () => {
    expect(sanitizeChatMessages(history, { historyOnly: true }).map(message => message.role)).toEqual(["user", "assistant"]);
  });
  it("still requires a new user turn for text chat", () => {
    expect(() => sanitizeChatMessages(history)).toThrow("must end with a user message");
    expect(sanitizeChatMessages([...history, history[0]])).toHaveLength(3);
  });
  it("drops non-text parts and permits empty voice history", () => {
    const messages = [{ role: "user" as const, parts: [{ type: "tool-result", text: "ignored" }] }];
    expect(sanitizeChatMessages(messages, { historyOnly: true })).toEqual([]);
    expect(() => sanitizeChatMessages(messages)).toThrow("must end with a user message");
  });
});
