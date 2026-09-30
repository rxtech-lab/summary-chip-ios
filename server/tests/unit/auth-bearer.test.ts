import { generateKeyPair, SignJWT } from "jose";
import { describe, expect, it } from "vitest";
import { verifyBearerToken } from "@/lib/auth/bearer";

const issuer = "https://auth.rxlab.app";

describe("bearer verification against a local JWKS key pair", () => {
  it("accepts RS256 tokens from the issuer with an allowed client_id", async () => {
    const { privateKey, publicKey } = await generateKeyPair("RS256");
    const token = await new SignJWT({ client_id: "ios-client", email: "a@example.test", scope: "openid profile" })
      .setProtectedHeader({ alg: "RS256", kid: "k1" })
      .setIssuer(issuer).setSubject("user-1").setIssuedAt().setExpirationTime("5m")
      .sign(privateKey);
    await expect(verifyBearerToken(token, { issuer: `${issuer}/`, allowedClientIds: new Set(["ios-client"]), key: publicKey }))
      .resolves.toMatchObject({ sub: "user-1", clientId: "ios-client", email: "a@example.test", scopes: ["openid", "profile"] });
    await expect(verifyBearerToken(token, { issuer, allowedClientIds: new Set(["other"]), key: publicKey }))
      .rejects.toMatchObject({ status: 403, code: "OAUTH_CLIENT_NOT_ALLOWED" });
  });

  it("rejects wrong issuer, expired, foreign-key and malformed tokens", async () => {
    const { privateKey, publicKey } = await generateKeyPair("RS256");
    const other = await generateKeyPair("RS256");
    const config = { issuer, allowedClientIds: new Set(["ios-client"]), key: publicKey };
    const wrongIssuer = await new SignJWT({ client_id: "ios-client" }).setProtectedHeader({ alg: "RS256" })
      .setIssuer("https://evil.example").setSubject("u").setExpirationTime("5m").sign(privateKey);
    const expired = await new SignJWT({ client_id: "ios-client" }).setProtectedHeader({ alg: "RS256" })
      .setIssuer(issuer).setSubject("u").setExpirationTime(Math.floor(Date.now() / 1000) - 60).sign(privateKey);
    const foreign = await new SignJWT({ client_id: "ios-client" }).setProtectedHeader({ alg: "RS256" })
      .setIssuer(issuer).setSubject("u").setExpirationTime("5m").sign(other.privateKey);
    for (const token of [wrongIssuer, expired, foreign, "not-a-jwt"]) {
      await expect(verifyBearerToken(token, config)).rejects.toMatchObject({ status: 401, code: "INVALID_ACCESS_TOKEN" });
    }
  });
});
