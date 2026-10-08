import { describe, expect, it } from "vitest";
import { assertPublicUrlSyntax, isPrivateAddress } from "@/lib/extract/ssrf";
import { searchTokens } from "@/lib/services/search";
import { normalizeDraft } from "@/lib/ai/summary-schema";
import { isBotUserAgent } from "@/lib/bots";

describe("searchTokens", () => {
  it("splits on whitespace and trims surrounding punctuation", () => {
    expect(searchTokens("  apple  AI ")).toEqual(["apple", "AI"]);
    expect(searchTokens('"on-device" (ai), 50%')).toEqual(["on-device", "ai", "50"]);
    expect(searchTokens("  ***  ")).toEqual([]);
    expect(searchTokens("人工智能 芯片")).toEqual(["人工智能", "芯片"]);
    expect(searchTokens("a b c d e f g h i j")).toHaveLength(8);
  });
});

describe("isPrivateAddress", () => {
  it.each(["127.0.0.1", "10.1.2.3", "172.16.5.4", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "::1", "fd00::1", "fe80::1", "::ffff:127.0.0.1", "::ffff:7f00:1"])("blocks %s", (address) => {
    expect(isPrivateAddress(address)).toBe(true);
  });
  it.each(["93.184.216.34", "1.1.1.1", "2606:4700:4700::1111"])("allows %s", (address) => {
    expect(isPrivateAddress(address)).toBe(false);
  });
});

describe("assertPublicUrlSyntax", () => {
  it("accepts public names without resolving them", () => {
    expect(assertPublicUrlSyntax("https://github.com/sirily11/msbd5017-docs").hostname).toBe("github.com");
    expect(assertPublicUrlSyntax("http://8.8.8.8/").hostname).toBe("8.8.8.8");
  });

  it("rejects local names, private literals, other schemes and credentials", () => {
    for (const url of ["http://localhost:3000/", "http://db.internal/", "http://printer.local/", "http://127.0.0.1/", "http://[::1]/", "http://10.0.0.5/", "ftp://example.com/", "https://user:pass@example.com/"]) {
      expect(() => assertPublicUrlSyntax(url), url).toThrow();
    }
  });
});

describe("normalizeDraft", () => {
  it("enforces contract limits on model output", () => {
    const draft = normalizeDraft({
      title: "  A title ",
      summary: "S.",
      highlights: ["1", "2", "3", "4", "5", "6", "7"],
      category: "Nonsense" as never,
      tags: ["AI", "#Apple", "ai", "x", "y", "z", "w", "v"],
      keywords: Array.from({ length: 15 }, (_, index) => `k${index}`),
      language: "en",
      design: { colors: ["#fff", "zzz", "#000000"], mode: "dark", emoji: "🍎 apple", accent: "not-hex", headline: "h".repeat(100) },
    }, { requestedLanguage: "ja", seed: "id" });
    expect(draft.highlights).toHaveLength(5);
    expect(draft.category).toBe("Other");
    expect(draft.tags).toEqual(["ai", "apple", "x", "y", "z", "w"]);
    expect(draft.keywords).toHaveLength(10);
    expect(draft.language).toBe("ja");
    expect(draft.theme.colors.length).toBeGreaterThanOrEqual(4);
    expect(draft.theme.colors.every((color) => /^#[0-9a-f]{6}$/.test(color))).toBe(true);
    expect(draft.theme.accent).toMatch(/^#[0-9a-f]{6}$/);
    expect(draft.theme.emoji).toBe("🍎");
    expect(draft.headline.length).toBeLessThanOrEqual(70);
  });
});

describe("isBotUserAgent", () => {
  it("detects link-preview crawlers", () => {
    expect(isBotUserAgent("facebookexternalhit/1.1 Facebot Twitterbot/1.0")).toBe(true);
    expect(isBotUserAgent("Slackbot-LinkExpanding 1.0")).toBe(true);
    expect(isBotUserAgent("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1")).toBe(false);
  });
});
