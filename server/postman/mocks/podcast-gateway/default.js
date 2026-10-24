/* Local gateway protocol fixture, derived from installed @ai-sdk/gateway v4 adapters.
 * Never deploy: intentionally uses fixture content and no authentication.
 */
// Postman executes mock handlers as CommonJS.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const http = require("node:http");
http.createServer(async (req, res) => {
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
  const user = body?.prompt?.find((part) => part.role === "user");
  let input;
  try { input = JSON.parse(user.content.find((part) => part.type === "text").text); }
  catch {
    res.writeHead(400, { "content-type": "application/json" });
    return res.end(JSON.stringify({ error: "Expected a structured podcast prompt" }));
  }
  const script = {
    title: "A day of discoveries",
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
