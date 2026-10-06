/**
 * A stand-in for RxAuth during end-to-end tests: publishes a JWKS at `/.well-known/jwks.json` (what
 * the server verifies bearer tokens against) and signs access tokens at `POST /token`.
 */
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { exportJWK, generateKeyPair, SignJWT } from "jose";
import { createHash, randomBytes } from "node:crypto";

const port = Number(process.env.MOCK_ISSUER_PORT ?? 3101);
const issuer = `http://127.0.0.1:${port}`;
const { publicKey, privateKey } = await generateKeyPair("RS256");
const jwk = { ...(await exportJWK(publicKey)), kid: "e2e", alg: "RS256", use: "sig" };
const codes = new Map<string, { clientId: string; redirectUri: string; challenge: string; sub: string }>();

interface TokenRequest {
  sub: string;
  clientId: string;
  scope?: string;
  expiresIn?: string;
}

async function readBody(request: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString("utf8");
}

function sendJson(response: ServerResponse, status: number, body: unknown): void {
  response.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(body));
}

createServer(async (request, response) => {
  const url = new URL(request.url ?? "/", issuer);
  const { pathname } = url;
  if (pathname === "/.well-known/jwks.json") return sendJson(response, 200, { keys: [jwk] });
  if (pathname === "/api/oauth/authorize") {
    const code = randomBytes(32).toString("base64url");
    codes.set(code, { clientId: url.searchParams.get("client_id")!, redirectUri: url.searchParams.get("redirect_uri")!,
      challenge: url.searchParams.get("code_challenge")!, sub: `e2e-mcp-${crypto.randomUUID()}` });
    const callback = new URL(url.searchParams.get("redirect_uri")!);
    callback.searchParams.set("code", code);
    callback.searchParams.set("state", url.searchParams.get("state")!);
    callback.searchParams.set("iss", issuer);
    response.writeHead(302, { location: callback.href }).end();
    return;
  }
  if (pathname === "/api/oauth/token" && request.method === "POST") {
    const fields = new URLSearchParams(await readBody(request));
    const code = fields.get("code") ?? "";
    const pending = codes.get(code);
    if (!pending || fields.get("client_id") !== pending.clientId || fields.get("redirect_uri") !== pending.redirectUri
      || fields.get("client_secret") !== "e2e-mcp-secret"
      || createHash("sha256").update(fields.get("code_verifier") ?? "").digest("base64url") !== pending.challenge) {
      return sendJson(response, 400, { error: "invalid_grant" });
    }
    codes.delete(code);
    const token = await new SignJWT({ client_id: pending.clientId, scope: "openid profile email" })
      .setProtectedHeader({ alg: "RS256", kid: "e2e" }).setIssuer(issuer).setSubject(pending.sub)
      .setIssuedAt().setExpirationTime("10m").sign(privateKey);
    return sendJson(response, 200, { access_token: token, token_type: "Bearer" });
  }
  if (pathname === "/token" && request.method === "POST") {
    const body = JSON.parse(await readBody(request)) as TokenRequest;
    const token = await new SignJWT({ client_id: body.clientId, scope: body.scope ?? "openid" })
      .setProtectedHeader({ alg: "RS256", kid: "e2e" })
      .setIssuer(issuer)
      .setSubject(body.sub)
      .setIssuedAt()
      .setExpirationTime(body.expiresIn ?? "10m")
      .sign(privateKey);
    return sendJson(response, 200, { access_token: token, token_type: "Bearer" });
  }
  sendJson(response, 404, { error: "not_found" });
}).listen(port, "127.0.0.1");

console.log(`[mock-issuer] listening on ${issuer}`);
