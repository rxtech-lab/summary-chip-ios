import { describe, expect, it } from "vitest";
import { MockAiProvider } from "@/lib/ai/mock";
import { findUrls, linkToFollow } from "@/lib/ai/shared-link";

const XHS_SHARE = "2026年国庆档的冷，不仅仅是宣发节奏问题，而是供给端... https://xhslink.cn/o/1RVs1hjAwxb \n先复制文字，再进【小红书】看看这篇宝贝笔记~";

describe("findUrls", () => {
  it("finds a URL inside CJK share text", () => {
    expect(findUrls(XHS_SHARE)).toEqual(["https://xhslink.cn/o/1RVs1hjAwxb"]);
  });

  it("stops at CJK punctuation and strips trailing punctuation", () => {
    expect(findUrls("看这里https://example.com/a?b=1，很好。See https://example.org/x).")).toEqual([
      "https://example.com/a?b=1",
      "https://example.org/x",
    ]);
  });

  it("ignores text without URLs", () => {
    expect(findUrls("no links here, just example.com")).toEqual([]);
  });
});

describe("linkToFollow", () => {
  it("does not ask the model when there is no URL", async () => {
    const ai = new MockAiProvider();
    expect(await linkToFollow(ai, "Plain notes about the meeting.")).toBeNull();
    expect(ai.calls.isSharedLink).toEqual([]);
  });

  it("follows a bare URL without asking the model", async () => {
    const ai = new MockAiProvider();
    expect(await linkToFollow(ai, "  https://example.com/post  ")).toBe("https://example.com/post");
    expect(ai.calls.isSharedLink).toEqual([]);
  });

  it("follows the link in a share snippet when the model says so", async () => {
    const ai = new MockAiProvider();
    expect(await linkToFollow(ai, XHS_SHARE)).toBe("https://xhslink.cn/o/1RVs1hjAwxb");
    expect(ai.calls.isSharedLink).toEqual([XHS_SHARE]);
  });

  it("summarises the text when the model says it is content", async () => {
    const ai = new MockAiProvider();
    ai.isSharedLink = async () => false;
    expect(await linkToFollow(ai, `${"A long article body. ".repeat(20)} Source: https://example.com/a`)).toBeNull();
  });
});
