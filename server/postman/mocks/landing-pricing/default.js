// Mirrors RxSubscription's app/api/v1/catalog/route.ts. No real credentials.
// Postman loads mock handlers as CommonJS.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const http = require("node:http");
http.createServer((request, response) => {
  const url = new URL(request.url, "http://localhost");
  const mode = url.pathname.split("/")[1];
  response.setHeader("Content-Type", "application/json");
  if (request.method !== "GET" || !url.pathname.endsWith("/api/v1/catalog") || url.searchParams.get("platform") !== "web") {
    response.writeHead(501).end(JSON.stringify({ error: "Unsupported request" }));
    return;
  }
  if (request.headers["x-api-key"] !== "rxs_production_pricing-fixture") {
    response.writeHead(401).end(JSON.stringify({ error: "Invalid fixture key" }));
    return;
  }
  if (mode === "outage") {
    response.writeHead(503).end(JSON.stringify({ error: "Unavailable" }));
    return;
  }
  if (mode === "malformed") {
    response.end(JSON.stringify({ topups: [{ priceAmountCents: -5 }] }));
    return;
  }
  const topups = mode === "empty" ? [] : [{
    id: "points-100", key: "points_100", name: "100 point pack", description: null,
    unit: "points", amount: 100, priceAmountCents: 199, currency: "usd",
    eligible: null, blockedBy: null,
    purchaseOptions: [{ provider: "stripe", flow: "checkout", priceAmountCents: 199, currency: "usd" }],
  }];
  response.end(JSON.stringify({ platform: "web", plans: [], topups }));
}).listen(process.env.PORT);
