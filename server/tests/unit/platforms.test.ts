import { describe, expect, it } from "vitest";
import { companyOf, platformOf, siteNameFor } from "@/lib/extract/platforms";

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

describe("siteNameFor", () => {
  it.each([
    ["https://x.com/user/status/1", "X"],
    ["https://mobile.twitter.com/user/status/1", "X"],
    ["https://www.threads.net/@user/post/abc", "Threads"],
    ["https://www.threads.com/@user/post/abc", "Threads"],
    ["https://m.facebook.com/page/posts/1", "Facebook"],
    ["https://fb.watch/abc", "Facebook"],
    ["https://www.youtube.com/watch?v=abcdefghijk", "YouTube"],
    ["https://youtu.be/abcdefghijk", "YouTube"],
  ])("credits %s to %s over the page's site name", (url, company) => {
    expect(companyOf(url)).toBe(company);
    expect(siteNameFor("youtube.com", url)).toBe(company);
  });

  it("keeps the site name for other sites", () => {
    expect(siteNameFor("The Verge", "https://www.theverge.com/a")).toBe("The Verge");
    expect(siteNameFor(null, "https://github.com/owner/repo")).toBeNull();
    expect(companyOf("https://notx.com/a")).toBeNull();
  });

  it("checks every URL, e.g. after a redirect", () => {
    expect(siteNameFor("t.co", "https://t.co/abc", "https://x.com/user/status/1")).toBe("X");
  });
});
