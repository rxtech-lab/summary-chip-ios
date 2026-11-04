import { describe, expect, it } from "vitest";
import { chatUITools } from "@/lib/ai/chat-ui";

describe("renderUI completeness", () => {
  it("rejects disconnected content and accepts the repaired tree", async () => {
    const execute = chatUITools().renderUI.execute!;
    const options = { toolCallId: "view", messages: [], context: {} };
    const elements = {
      intro: { type: "Text", props: { text: "Investment overview:" } },
      details: { type: "List", props: { items: ["Investment details"] } },
    };
    const rejected = await execute({ title: "Overview", spec: { root: "intro", elements } }, options);
    expect(rejected).toMatchObject({ error: expect.any(String), issues: [expect.stringContaining("details: element is not reachable")] });
    expect(rejected).not.toHaveProperty("ui");
    const repaired = await execute({ title: "Overview", spec: {
      root: "root", elements: { ...elements, root: { type: "Stack", props: {}, children: ["intro", "details"] } },
    } }, options);
    expect(repaired).toHaveProperty("ui");
    expect(repaired).toHaveProperty("text", "Investment overview:\n- Investment details");
  });
});
