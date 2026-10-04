import { connect } from "node:http2";
import { importPKCS8, SignJWT } from "jose";

export interface PushTarget { token: string; environment: "sandbox" | "production" }
export interface PushPayload {
  aps: { alert: { title: string; body: string }; sound: string };
  summaryId: string;
  userId: string;
}
export interface PushResult { status: number; reason?: string }

export function apnsConfigured(): boolean {
  return Boolean(process.env.APNS_KEY_ID && process.env.APNS_TEAM_ID && process.env.APNS_PRIVATE_KEY);
}

// Apple accepts provider tokens for an hour; reuse for 50 minutes.
let cached: { config: string; token: string; until: number } | undefined;
async function providerToken(): Promise<string> {
  const keyId = process.env.APNS_KEY_ID!;
  const teamId = process.env.APNS_TEAM_ID!;
  const pem = process.env.APNS_PRIVATE_KEY!.replace(/\\n/g, "\n");
  const config = JSON.stringify([keyId, teamId, pem]);
  if (cached?.config === config && cached.until > Date.now()) return cached.token;
  const key = await importPKCS8(pem, "ES256");
  const token = await new SignJWT({}).setProtectedHeader({ alg: "ES256", kid: keyId }).setIssuer(teamId).setIssuedAt().sign(key);
  cached = { config, token, until: Date.now() + 50 * 60_000 };
  return token;
}

/** Native HTTP/2: APNs doesn't accept fetch's HTTP/1.1 transport. No device tokens in logs. */
export async function sendPush(target: PushTarget, payload: PushPayload): Promise<PushResult> {
  const authorization = await providerToken();
  const host = target.environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  return new Promise((resolve, reject) => {
    const session = connect(`https://${host}`);
    const timer = setTimeout(() => finish(new Error("APNs request timed out")), 10_000);
    let settled = false;
    const finish = (error?: Error, result?: PushResult) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      session.destroy();
      if (error) reject(error);
      else resolve(result!);
    };
    session.on("error", () => finish(new Error("APNs connection failed")));
    const request = session.request({
      ":method": "POST", ":path": `/3/device/${target.token}`,
      authorization: `bearer ${authorization}`,
      "apns-topic": process.env.APNS_BUNDLE_ID || "com.rxlab.summary-chip",
      "apns-push-type": "alert", "apns-priority": "10",
      "apns-expiration": String(Math.floor(Date.now() / 1000) + 86_400),
      "apns-collapse-id": payload.summaryId,
    });
    let status = 0;
    let body = "";
    request.setEncoding("utf8");
    request.on("response", (headers) => { status = Number(headers[":status"]); });
    request.on("data", (chunk: string) => { body = (body + chunk).slice(0, 4096); });
    request.on("error", () => finish(new Error("APNs request failed")));
    request.on("end", () => {
      let reason: string | undefined;
      try { reason = JSON.parse(body).reason; } catch { /* Successful pushes have no body. */ }
      finish(undefined, { status, reason });
    });
    request.on("close", () => { if (!settled) finish(new Error("APNs request closed early")); });
    request.end(JSON.stringify(payload));
  });
}
