/**
 * A stand-in for RxAuth during end-to-end tests: publishes a JWKS at `/.well-known/jwks.json` (what
 * the server verifies bearer tokens against) and signs access tokens at `POST /token`.
 */
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { exportJWK, generateKeyPair, SignJWT } from "jose";

const port = Number(process.env.MOCK_ISSUER_PORT ?? 3101);
const issuer = `http://127.0.0.1:${port}`;
const { publicKey, privateKey } = await generateKeyPair("RS256");
const jwk = { ...(await exportJWK(publicKey)), kid: "e2e", alg: "RS256", use: "sig" };

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
  const { pathname } = new URL(request.url ?? "/", issuer);
  if (pathname === "/.well-known/jwks.json") return sendJson(response, 200, { keys: [jwk] });
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
