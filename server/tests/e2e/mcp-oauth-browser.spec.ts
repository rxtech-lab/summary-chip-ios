import { createHash, randomBytes } from "node:crypto";
import { expect, test } from "@playwright/test";

const ORIGIN = "http://127.0.0.1:3100";
const CALLBACK = "http://127.0.0.1:3101/mcp-callback";

for (const decision of ["allow", "deny"] as const) {
  test(`browser consent ${decision} preserves the origin and reaches the agent callback`, async ({ page, request }, testInfo) => {
    await page.setViewportSize(decision === "allow" ? { width: 1280, height: 960 } : { width: 375, height: 812 });
    await page.emulateMedia({ colorScheme: decision === "allow" ? "light" : "dark" });
    const registered = await request.post("/api/mcp/oauth/register", {
      data: { client_name: "Browser verification agent", redirect_uris: [CALLBACK] },
    });
    expect(registered.status()).toBe(201);
    const clientId = (await registered.json()).client_id;
    const verifier = randomBytes(32).toString("base64url");
    const authorize = new URL(`${ORIGIN}/api/mcp/oauth/authorize`);
    authorize.search = new URLSearchParams({ client_id: clientId, redirect_uri: CALLBACK, response_type: "code",
      resource: `${ORIGIN}/api/mcp`, scope: "chippy:read chippy:write", state: "browser-verification", code_challenge_method: "S256",
      code_challenge: createHash("sha256").update(verifier).digest("base64url") }).toString();
    await page.goto(authorize.href);
    await expect(page.getByRole("button", { name: "Allow access" })).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await page.screenshot({ path: testInfo.outputPath("consent.png"), fullPage: true });
    const submitted = page.waitForRequest(req => req.method() === "POST" && req.url() === `${ORIGIN}/api/mcp/oauth/consent`);
    await page.getByRole("button", { name: decision === "allow" ? "Allow access" : "Cancel", exact: true }).click();
    // A real form navigation synthesizes this header; API fixtures setting it manually miss the bug.
    expect(await (await submitted).headerValue("origin")).toBe(ORIGIN);
    await expect(page.getByRole("heading", { name: "Agent callback received" })).toBeVisible();
    const callback = new URL(page.url());
    expect(callback.searchParams.get("state")).toBe("browser-verification");
    expect(callback.searchParams.get("iss")).toBe(ORIGIN);
    if (decision === "deny") {
      expect(callback.searchParams.get("error")).toBe("access_denied");
      expect(callback.searchParams.has("code")).toBe(false);
    } else {
      const response = await request.post("/api/mcp/oauth/token", { form: { grant_type: "authorization_code", client_id: clientId,
        redirect_uri: CALLBACK, resource: `${ORIGIN}/api/mcp`, code: callback.searchParams.get("code")!, code_verifier: verifier } });
      expect(response.status()).toBe(200);
      const token = (await response.json()).access_token;
      const profile = await request.post("/api/mcp", { headers: { authorization: `Bearer ${token}`, accept: "application/json, text/event-stream" },
        data: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "get_profile", arguments: {} } } });
      expect(profile.status()).toBe(200);
      expect((await profile.json()).result.structuredContent.id).toMatch(/^e2e-mcp-/);
    }
  });
}

for (const restricted of [true, false]) {
  test(`callback redirect chain with ${restricted ? "old restricted" : "fixed"} CSP`, async ({ page, request }) => {
    const consoleErrors: string[] = [];
    page.on("console", message => consoleErrors.push(message.text()));
    const callback = "http://127.0.0.1:3101/mcp-redirect-callback";
    const registered = await request.post("/api/mcp/oauth/register", {
      data: { client_name: "Redirecting web agent", redirect_uris: [callback] },
    });
    const clientId = (await registered.json()).client_id;
    const verifier = randomBytes(32).toString("base64url");
    const authorize = new URL(`${ORIGIN}/api/mcp/oauth/authorize`);
    authorize.search = new URLSearchParams({ client_id: clientId, redirect_uri: callback, response_type: "code",
      resource: `${ORIGIN}/api/mcp`, state: "redirect-chain", code_challenge_method: "S256",
      code_challenge: createHash("sha256").update(verifier).digest("base64url") }).toString();
    // Web agents can accept the code on one origin and return users to their app on another.
    const completion = "http://localhost:3101/mcp-callback";
    await page.goto(authorize.href);
    if (restricted) await page.evaluate(() => {
      const policy = document.createElement("meta");
      policy.httpEquiv = "Content-Security-Policy";
      policy.content = "form-action 'self' http://127.0.0.1:3101";
      document.head.append(policy);
    });
    await page.getByRole("button", { name: "Allow access", exact: true }).click();
    if (restricted) {
      await expect.poll(() => consoleErrors.join("\n")).toContain("form-action");
      // Approval succeeded, but the browser stayed on the form. Retry gives the reported error.
      await page.getByRole("button", { name: "Allow access", exact: true }).click();
      await expect(page.locator("body")).toContainText("The consent request is expired or belongs to another browser.");
    } else {
      await expect(page).toHaveURL(completion);
      await expect(page.getByRole("heading", { name: "Agent callback received" })).toBeVisible();
    }
  });
}
