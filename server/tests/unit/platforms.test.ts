import { describe, expect, it } from "vitest";
import { platformOf } from "@/lib/extract/platforms";

describe("platformOf", () => {
  it.each([
    ["https://x.com/user/status/1", "x"],
    ["https://mobile.twitter.com/user/status/1", "x"],
    ["https://www.facebook.com/page/posts/1", "facebook"],
    ["https://fb.watch/abc", "facebook"],
    ["https://m.youtube.com/watch?v=abcdefghijk", "youtube"],
    ["https://youtu.be/abcdefghijk", "youtube"],
    ["https://github.com/owner/repo", "github"],
    ["https://gist.github.com/owner/1", "github"],
  ])("detects %s as %s", (url, platform) => {
    expect(platformOf(url)).toBe(platform);
  });

  it.each([
    "https://news.example.com/a",
    "https://notx.com/a",
    "https://github.io/a",
    "https://myyoutube.com/watch",
    "not a url",
    null,
  ])("leaves %s on the open web", (url) => {
    expect(platformOf(url)).toBeNull();
  });
});
