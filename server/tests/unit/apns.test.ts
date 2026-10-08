import { EventEmitter } from "node:events";
import { exportPKCS8, generateKeyPair, jwtVerify } from "jose";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { apnsConfigured, sendPush } from "@/lib/notifications/apns";

const { connect } = vi.hoisted(() => ({ connect: vi.fn() }));
vi.mock("node:http2", () => ({ connect }));
const payload = { aps: { alert: { title: "Summary added", body: "Monarchs" }, sound: "default" }, summaryId: "summary-id", userId: "alice" };
let keys: Awaited<ReturnType<typeof generateKeyPair>>;

beforeEach(async () => {
  keys = await generateKeyPair("ES256", { extractable: true });
  vi.stubEnv("APNS_PRIVATE_KEY", (await exportPKCS8(keys.privateKey)).replace(/\n/g, "\\n"));
  vi.stubEnv("APNS_KEY_ID", "test-key");
  vi.stubEnv("APNS_TEAM_ID", "test-team");
  vi.stubEnv("APNS_BUNDLE_ID", "com.rxlab.summary-chip");
  connect.mockReset();
});
afterEach(() => vi.unstubAllEnvs());

function transport(status: number, body = "", error = false) {
  const request = Object.assign(new EventEmitter(), {
    setEncoding: vi.fn(),
    end: vi.fn(() => queueMicrotask(() => {
      if (error) { request.emit("error", new Error("sensitive token must not escape")); return; }
      request.emit("response", { ":status": status });
      if (body) request.emit("data", body);
      request.emit("end");
    })),
  });
  const session = Object.assign(new EventEmitter(), { request: vi.fn<(headers: Record<string, string>) => typeof request>(() => request), destroy: vi.fn() });
  connect.mockReturnValue(session);
  return { request, session };
}

it("uses sandbox HTTP/2, signs the provider token, sends the payload and closes the connection", async () => {
  const { request, session } = transport(200);
  expect(apnsConfigured()).toBe(true);
  expect(await sendPush({ token: "abc123", environment: "sandbox" }, payload)).toEqual({ status: 200 });
  expect(connect).toHaveBeenCalledWith("https://api.sandbox.push.apple.com");
  const headers = session.request.mock.calls[0][0];
  expect(headers).toMatchObject({ ":method": "POST", ":path": "/3/device/abc123", "apns-push-type": "alert", "apns-topic": "com.rxlab.summary-chip", "apns-collapse-id": payload.summaryId });
  const verified = await jwtVerify(headers.authorization.slice(7), keys.publicKey, { issuer: "test-team", algorithms: ["ES256"] });
  expect(verified.protectedHeader.kid).toBe("test-key");
  expect(verified.payload.iat).toEqual(expect.any(Number));
  expect(request.end).toHaveBeenCalledWith(JSON.stringify(payload));
  expect(session.destroy).toHaveBeenCalledTimes(1);
});

it("selects production and returns APNs rejection details", async () => {
  const { session } = transport(410, '{"reason":"Unregistered"}');
  expect(await sendPush({ token: "abc123", environment: "production" }, payload)).toEqual({ status: 410, reason: "Unregistered" });
  expect(connect).toHaveBeenCalledWith("https://api.push.apple.com");
  expect(session.destroy).toHaveBeenCalledTimes(1);
});

it("expires a time-sensitive reminder at its supplied deadline", async () => {
  const { session } = transport(200);
  await sendPush({ token: "abc123", environment: "sandbox" }, payload, { expiration: 1_800_000_000, collapseId: "leg-reminder" });
  expect(session.request.mock.calls[0][0]).toMatchObject({ "apns-expiration": "1800000000", "apns-collapse-id": "leg-reminder" });
});

it("closes a failed request and exposes a redacted error", async () => {
  const { session } = transport(0, "", true);
  await expect(sendPush({ token: "abc123", environment: "sandbox" }, payload)).rejects.toThrow("APNs request failed");
  expect(session.destroy).toHaveBeenCalledTimes(1);
});

it("reports missing credentials as unconfigured", () => {
  vi.stubEnv("APNS_PRIVATE_KEY", "");
  expect(apnsConfigured()).toBe(false);
});
