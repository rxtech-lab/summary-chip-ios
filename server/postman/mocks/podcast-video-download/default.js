// Local contract fixture for the native client, not a playable MP4 or live storage.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const http = require("node:http");
http.createServer((req, res) => {
  const url = new URL(req.url, "http://fixture.invalid");
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
