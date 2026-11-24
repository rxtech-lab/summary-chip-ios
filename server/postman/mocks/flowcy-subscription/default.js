// Contract fixture for the GitHub Autopilot subscription project. All accounts and keys are fictional.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const http = require("node:http");
const planId = "8efd0160-848f-448f-968f-ec2129566829";
const productId = "com.rxlab.chippy.flowcy.plus.monthly";
const appleMembers = new Set();

http.createServer(async (request, response) => {
  const url = new URL(request.url, "http://localhost");
  const send = (status, data) => response.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(data));
  if (request.headers["x-api-key"] !== "rxs_production_fixture") return send(401, { error: "Invalid fixture key" });
  if (url.pathname.includes("/unavailable/")) return send(503, { error: "Unavailable" });
  if (request.method === "GET" && url.pathname.endsWith("/api/v1/entitlements")) {
    const user = url.searchParams.get("rxlabUserId");
    if (!user) return send(400, { error: "Missing account" });
    const plus = { planId, status: "active", currentPeriodEnd: "2099-02-01T00:00:00Z" };
    const plans = appleMembers.has(user) ? [{ ...plus, billingProvider: "apple_app_store" }]
      : user === "user-bob" ? [{ ...plus, billingProvider: "stripe" }] : [];
    return send(200, { plans, defaultPlans: [{ status: "active", planId: "free", billingProvider: "internal", currentPeriodEnd: null }] });
  }
  if (request.method === "GET" && url.pathname.endsWith("/api/v1/catalog") && url.searchParams.get("platform") === "ios") {
    return send(200, { plans: [{ id: planId, purchaseOptions: [
      { provider: "apple_app_store", productType: "auto_renewable_subscription", productId },
    ] }] });
  }
  if (request.method === "POST" && url.pathname.includes("/api/v1/iap/apple/")) {
    const body = request.body;
    const { rxlabUserId, signedTransaction } = typeof body === "string" ? JSON.parse(body) : body ?? {};
    if (!rxlabUserId) return send(400, { error: "Missing account" });
    if (url.pathname.endsWith("/account-token")) return send(200, { appAccountToken: "0c63980e-0bd3-45c1-bdcf-85211433867e" });
    if (url.pathname.endsWith("/transactions")) {
      if (signedTransaction !== "signed-apple-transaction-fixture") return send(422, { error: "Invalid StoreKit proof" });
      appleMembers.add(rxlabUserId);
      return send(200, { status: "fulfilled" });
    }
  }
  return send(501, { error: "Unsupported fixture request" });
}).listen(process.env.PORT);
