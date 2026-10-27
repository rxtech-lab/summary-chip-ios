// Local contract fixture for the native client, not a playable MP4 or live storage.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const http = require("node:http");
http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://fixture.invalid");
  if (url.pathname.endsWith("/video/render") && ["POST", "GET"].includes(req.method)) {
    if (req.headers.authorization !== "Bearer podcast-download-fixture") { res.writeHead(401); return res.end(); }
    let body;
    if (req.method === "POST") {
      body = req.body;
    }
    const language = body?.language ?? url.searchParams.get("language");
    const resolution = body?.resolution ?? Number(url.searchParams.get("resolution"));
    const start = body?.day?.start ?? url.searchParams.get("start");
    if (language !== "ja" || resolution !== 1080 || start !== "2030-04-01T00:00:00Z") {
      res.writeHead(400); return res.end("Expected translated 1080p episode");
    }
    const key = url.pathname.split("/")[4];
    const state = key === "failed" ? "failed" : req.method === "POST" ? "running" : "ready";
    const videoId = key === "stale" ? "replaced-video" : "published-video";
    res.writeHead(200, { "content-type": "application/json", "cache-control": "private, no-store" });
    return res.end(JSON.stringify({ videoId, render: { id: "render-1", status: state, resolution: 1080, byteSize: state === "ready" ? 4 : undefined,
      ...(state === "failed" ? { error: { code: "PODCAST_RENDER_FAILED", message: "Render failed" } } : {}) },
      ...(state === "ready" ? { downloadUrl: `${req.headers["x-fixture-base"]}/storage/${key}.mp4` } : {}) }));
  }
  if (req.method === "GET" && url.pathname.endsWith("/video/publication")) {
    if (req.headers.authorization !== "Bearer podcast-download-fixture") {
      res.writeHead(401); return res.end();
    }
    if (url.searchParams.get("start") !== "2030-04-01T00:00:00Z" || url.searchParams.get("language") !== "ja") {
      res.writeHead(400); return res.end("Expected episode day and translation");
    }
    const key = url.pathname.split("/")[4];
    const videoId = key === "stale" ? "replaced-video" : "published-video";
    res.writeHead(200, { "content-type": "application/json", "cache-control": "private, no-store" });
    return res.end(JSON.stringify({ videoId, downloadUrl: `${req.headers["x-fixture-base"]}/storage/${key}.mp4` }));
  }
  if (req.method === "GET" && url.pathname.startsWith("/storage/")) {
    if (req.headers.authorization) { res.writeHead(400); return res.end("Account token leaked to storage"); }
    const bytes = Buffer.from(url.pathname.includes("truncated") ? "mp" : "mp4!");
    res.writeHead(200, { "content-type": "video/mp4", "content-length": String(bytes.length) });
    return res.end(bytes);
  }
  res.writeHead(501); res.end("Endpoint not modeled");
}).listen(process.env.PORT);
