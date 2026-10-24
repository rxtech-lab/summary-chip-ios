/* Local gateway protocol fixture, derived from installed @ai-sdk/gateway v4 adapters.
 * Never deploy: intentionally uses fixture content and no authentication.
 */
// Postman executes mock handlers as CommonJS.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const http = require("node:http");
http.createServer(async (req, res) => {
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
    const bytes = Buffer.alloc(417 * 4);
    for (let at = 0; at < bytes.length; at += 417) bytes.set([255, 251, 144, 192], at);
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
    const storyboard = episode.segments.map((segment, segmentIndex) => ({ segmentIndex, sourceQuote: segment.caption.slice(0, 1200), visualSubject: "Fixture source", visualAction: "Fixture panel expands with the current voice progress", file: "src/Video.tsx" }));
    const call = { type: "tool-call", toolCallId: "video-1", toolName: "submit_video", input: JSON.stringify({ storyboard, files: [{
      path: "src/Video.tsx", content: 'import { AbsoluteFill } from "remotion"; import { useNarration } from "./podcast"; export const PodcastVideo = () => { const { index, progress } = useNarration(); return <AbsoluteFill style={{backgroundColor: "#111"}}><div style={{width: 100 + progress * 200}}>Fixture turn {index}</div></AbsoluteFill>; };',
    }] }) };
    const finishReason = { unified: "tool-calls", raw: "tool_calls" };
    const usage = { inputTokens: { total: 10, noCache: 10, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 10, text: 10, reasoning: 0 } };
    if (body?.tools?.some((tool) => tool.name === "submit_video")) {
      res.writeHead(200, { "content-type": "text/event-stream" });
      for (const part of [{ type: "stream-start", warnings: [] }, call, { type: "finish", finishReason, usage }]) res.write(`data: ${JSON.stringify(part)}\n\n`);
      return res.end();
    }
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
  const script = {
    title: "A day of discoveries",
    mood: "focused",
    speakers: input.voices.slice(0, 2).map((voice, index) => ({ name: index ? "Sam" : "Alex", voice })),
    segments: input.chips.map((chip, index) => ({ speaker: index % Math.min(input.voices.length, 2), chipId: chip.id, caption: chip.summary })),
  };
  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify({
    content: [{ type: "text", text: JSON.stringify(script) }],
    finishReason: { unified: "stop", raw: "stop" },
    usage: { inputTokens: { total: 10, noCache: 10, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 10, text: 10, reasoning: 0 } }, warnings: [],
  }));
}).listen(process.env.PORT);
