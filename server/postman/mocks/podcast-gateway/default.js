/* Local gateway protocol fixture, derived from installed @ai-sdk/gateway v4 adapters.
 * Never deploy: intentionally uses fixture content and no authentication.
 */
// Postman executes mock handlers as CommonJS.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const http = require("node:http");
http.createServer(async (req, res) => {
  if (req.headers["x-podcast-fixture-failure"] === "hang") {
    // Longer than the regression test's client deadline; no production request uses this header.
    const timer = setTimeout(() => { res.writeHead(504); res.end("Fixture timeout"); }, 1000);
    res.on("close", () => clearTimeout(timer));
    return;
  }
  if (req.method === "POST" && req.url === "/transcription-model") {
    if (!req.body?.audio || req.body?.providerOptions?.mistral?.timestampGranularities?.[0] !== "segment") {
      res.writeHead(400); return res.end("Expected audio and segment timestamps");
    }
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify({ text: "Welcome to Rexlab. Here is the news.", segments: [
      { text: "Welcome to Rexlab.", startSecond: 0.3, endSecond: 2.1 },
      { text: "Here is the news.", startSecond: 2.8, endSecond: 4.2 }
    ], warnings: [] }));
  }
  if (req.method === "POST" && req.url === "/evaluation-model") {
    if (!req.body?.state || req.body?.questions?.progress?.type !== "choice") {
      res.writeHead(400); return res.end("Invalid progress evaluation");
    }
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify({ answers: { progress: { type: "choice", choice: "middle" } } }));
  }
  if (req.method === "POST" && req.url === "/speech-model") {
    if (!req.body?.text || !req.body?.voice || req.body?.outputFormat !== "mp3") {
      res.writeHead(400, { "content-type": "application/json" });
      return res.end(JSON.stringify({ error: "Expected text, voice and MP3 output" }));
    }
    // Preserve the spoken text in an ID3 title, matching the local transcription fixture.
    const title = Buffer.from(req.body.text);
    const tagSize = 11 + title.length;
    const syncsafe = size => [(size >> 21) & 127, (size >> 14) & 127, (size >> 7) & 127, size & 127];
    const bytes = Buffer.alloc(10 + tagSize + 417 * 4);
    bytes.set([73, 68, 51, 4, 0, 0, ...syncsafe(tagSize)]);
    bytes.set([84, 73, 84, 50, ...syncsafe(title.length + 1), 0, 0, 3], 10);
    bytes.set(title, 21);
    for (let at = 10 + tagSize; at < bytes.length; at += 417) bytes.set([255, 251, 144, 192], at);
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify({ audio: bytes.toString("base64"), warnings: [] }));
  }
  if (req.method !== "POST" || req.url !== "/language-model") {
    res.writeHead(501, { "content-type": "application/json" });
    return res.end(JSON.stringify({ error: "Endpoint outside this fixture's contract" }));
  }
  const body = req.body;
  if (body?.tools?.some((tool) => tool.name === "submit_video")) {
    let episode;
    try {
      const text = body.prompt.flatMap(part => Array.isArray(part.content) ? part.content : []).find(part => part.type === "text" && part.text.includes("<episode>"))?.text;
      episode = JSON.parse(text.match(/<episode>\s*([\s\S]*?)\s*<\/episode>/)[1]);
    } catch {
      res.writeHead(400); return res.end("Expected a video episode prompt");
    }
    const storyboard = episode.turns.map((segment, segmentIndex) => ({ segmentIndex, sourceQuote: segment.caption.slice(0, 1200), visualSubject: "Fixture source", visualAction: "Fixture panel expands with the current voice progress", phraseActions: [{ phrase: 0, action: "Panel expands" }], storyTransition: "Previous panel exits as the next panel expands", file: "src/Video.tsx" }));
    const call = { type: "tool-call", toolCallId: "video-1", toolName: "submit_video", input: JSON.stringify({ storyboard, files: [{
      path: "src/Video.tsx", content: 'import { AbsoluteFill } from "remotion"; import { usePhrases } from "./podcast"; export const PodcastVideo = () => { const { index, progress } = usePhrases(); return <AbsoluteFill style={{backgroundColor: "#111"}}><div style={{width: 100 + progress * 200}}>Fixture turn {index}</div></AbsoluteFill>; };',
    }] }) };
    const finishReason = { unified: "tool-calls", raw: "tool_calls" };
    const usage = { inputTokens: { total: 10, noCache: 10, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 10, text: 10, reasoning: 0 } };
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify({ content: [call], finishReason, usage, warnings: [] }));
  }

  const user = body?.prompt?.find((part) => part.role === "user");
  let input;
  try { input = JSON.parse(user.content.find((part) => part.type === "text").text); }
  catch {
    res.writeHead(400, { "content-type": "application/json" });
    return res.end(JSON.stringify({ error: "Expected a structured podcast prompt" }));
  }
  if (Array.isArray(input.transcript)) {
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify({ content: [{ type: "text", text: JSON.stringify({ summary: "A concise overview of the recorded discoveries and their implications." }) }],
      finishReason: { unified: "stop", raw: "stop" }, warnings: [],
      usage: { inputTokens: { total: 10, noCache: 10, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 10, text: 10, reasoning: 0 } } }));
  }
  if (Array.isArray(input.segments)) {
    const article = { description: "A closer look at the episode’s discoveries.", sections: input.segments.map((segment) => ({
      heading: `Discovery ${segment.segmentIndex + 1}`, paragraphs: ["The findings offer a useful perspective on the topic discussed in this episode."], segmentIndex: segment.segmentIndex,
    })) };
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify({ content: [{ type: "text", text: JSON.stringify(article) }],
      finishReason: { unified: "stop", raw: "stop" }, usage: { inputTokens: { total: 10 }, outputTokens: { total: 10 } }, warnings: [] }));
  }
  const script = {
    title: "A day of discoveries",
    summary: "A roundup of the recorded discoveries and their key takeaways.",
    ...(input.recap ? { rankedChipIds: input.chips.map(chip => chip.id) } : {}),
    mood: "focused",
    speakers: input.voices.slice(0, input.speakerNames?.length ?? 2).map((voice, index) => ({ name: input.speakerNames?.[index] ?? (index ? "Sam" : "Alex"), voice })),
    segments: input.chips.map((chip, index) => ({ speaker: index % Math.min(input.voices.length, input.speakerNames?.length ?? 2), chipId: chip.id, caption: chip.summary, ...(input.storyboard ? { camera: "Wide shot of the source artwork, slow push in, then dissolve." } : {}) })),
  };
  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify({
    content: [{ type: "text", text: JSON.stringify(script) }],
    finishReason: { unified: "stop", raw: "stop" },
    usage: { inputTokens: { total: 10, noCache: 10, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 10, text: 10, reasoning: 0 } }, warnings: [],
  }));
}).listen(process.env.PORT);
