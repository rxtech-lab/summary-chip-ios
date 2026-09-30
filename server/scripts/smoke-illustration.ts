import { writeFileSync } from "node:fs";
import { GatewayAiProvider, type DesignInput } from "@/lib/ai/provider";
import { renderOgPng } from "@/lib/og/render";

process.env.AI_IMAGE_MODEL ||= "google/gemini-3.1-flash-lite-image";
const designs: Record<string, DesignInput> = {
  en: {
    title: "Apple unveils M6 chip with on-device AI",
    headline: "Apple's M6 chip brings faster on-device AI",
    summary: "Apple announced the M6 chip.",
    category: "Technology",
    keywords: ["apple", "m6", "chip", "on-device ai", "neural engine"],
    colors: ["#0f172a", "#1e3a8a", "#6366f1", "#f472b6"],
    mode: "dark",
    siteLabel: "apple.com",
    language: "en",
  },
  zh: {
    title: "英国警告：学术合作或被用于间谍活动",
    headline: "英国警告：学术合作或被用于间谍活动",
    summary: "英国军情五处称，中国通用技术研究院与中国国家安全部关系密切。",
    category: "World",
    keywords: ["军情五处", "学术研究", "间谍", "英国", "中国"],
    colors: ["#0b1220", "#1f2a44", "#3b4a6b", "#f59e0b"],
    mode: "dark",
    siteLabel: "BBC News 中文",
    language: "zh",
  },
};
const provider = new GatewayAiProvider();
await Promise.all(Object.entries(designs).map(async ([name, design]) => {
  const started = Date.now();
  const png = await provider.illustrate(design);
  console.log(name, png ? `${png.byteLength} bytes` : null, `${Date.now() - started}ms`);
  if (!png) return;
  writeFileSync(`/tmp/summary-art-${name}.png`, png);
  const card = await renderOgPng({
    headline: design.headline,
    category: design.category,
    siteLabel: design.siteLabel ?? null,
    colors: design.colors,
    mode: design.mode,
    accent: design.colors.at(-1)!,
    language: design.language ?? "en",
    image: png,
  });
  writeFileSync(`/tmp/summary-og-${name}.png`, card);
}));
