import { readFileSync } from "node:fs";
import path from "node:path";
import { Environment, SignedDataVerifier, VerificationException, VerificationStatus } from "@apple/app-store-server-library";
import { ApiError } from "@/lib/http/errors";
import { subscriptionConfig, type BillingEnvironment } from "./config";
import type { ApiPrincipal } from "@/lib/auth/bearer";

const verifiers = new Map<string, SignedDataVerifier>();

/** Apple proves sandbox/production; server-authorized testers may use isolated Xcode funds. */
export async function billingEnvironment(request: Request, principal: Pick<ApiPrincipal, "sub">): Promise<BillingEnvironment | undefined> {
  const explicitlyXcode = process.env.RX_SUBSCRIPTION_ENVIRONMENT?.trim() === "xcode";
  if (request.headers.get("x-storekit-environment") === "xcode" || explicitlyXcode) {
    const deployed = process.env.NODE_ENV === "production" || Boolean(process.env.VERCEL_ENV && process.env.VERCEL_ENV !== "development");
    const testers = new Set((process.env.RX_SUBSCRIPTION_XCODE_USER_IDS ?? "").split(",").map(value => value.trim()).filter(Boolean));
    if (deployed && !testers.has(principal.sub)) {
      throw new ApiError(403, "XCODE_BILLING_NOT_ALLOWED", "Xcode billing is not enabled for this test account.");
    }
    if (!subscriptionConfig("xcode")) throw new ApiError(503, "SUBSCRIPTION_NOT_CONFIGURED", "Xcode billing is not configured.");
    return "xcode";
  }
  if (!process.env.RX_SUBSCRIPTION_SANDBOX_API_KEY && !process.env.RX_SUBSCRIPTION_PRODUCTION_API_KEY) return undefined;
  const proof = request.headers.get("x-storekit-app-transaction");
  if (!proof) return "production";
  if (proof.length > 16_384 || proof.split(".").length !== 3) throw invalidProof();
  const bundleId = process.env.APPLE_BUNDLE_ID?.trim() || "com.rxlab.summary-chip";
  const parsedAppId = Number(process.env.APP_STORE_ID);
  const appId = Number.isSafeInteger(parsedAppId) && parsedAppId > 0 ? parsedAppId : undefined;
  // Apple only requires the app ID to verify production proofs. Without it, still detect sandbox and otherwise
  // fall back to production — the same default as a request without proof — so usage is never blocked.
  const environments = appId
    ? [[Environment.SANDBOX, "sandbox"], [Environment.PRODUCTION, "production"]] as const
    : [[Environment.SANDBOX, "sandbox"]] as const;
  for (const expectedBundle of [bundleId, `${bundleId}.Clip`]) {
    for (const [apple, billing] of environments) {
      try {
        const key = `${expectedBundle}:${apple}:${appId ?? "none"}`;
        let verifier = verifiers.get(key);
        if (!verifier) {
          const root = readFileSync(path.join(process.cwd(), "lib/subscription/certificates/AppleRootCA-G3.cer"));
          verifier = new SignedDataVerifier([root], true, apple, expectedBundle, appId);
          verifiers.set(key, verifier);
        }
        await verifier.verifyAndDecodeAppTransaction(proof);
        return billing;
      } catch (error) {
        if (!(error instanceof VerificationException)) throw error;
        if (error.status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE) throw new ApiError(503, "BILLING_VERIFICATION_UNAVAILABLE", "Apple verification is unavailable. Please try again.");
        if (error.status !== VerificationStatus.INVALID_ENVIRONMENT && error.status !== VerificationStatus.INVALID_APP_IDENTIFIER) throw invalidProof();
      }
    }
  }
  if (!appId) return "production";
  throw invalidProof();
}

function invalidProof() {
  return new ApiError(403, "INVALID_BILLING_ENVIRONMENT", "The app's billing environment could not be verified.");
}
