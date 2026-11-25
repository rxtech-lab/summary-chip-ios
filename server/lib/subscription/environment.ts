import { readFileSync } from "node:fs";
import path from "node:path";
import { Environment, SignedDataVerifier, VerificationException, VerificationStatus } from "@apple/app-store-server-library";
import { ApiError } from "@/lib/http/errors";
import { isDeployed } from "./flowcy";

const verifiers = new Map<string, SignedDataVerifier>();
export type SubscriptionEnvironment = "production" | "sandbox" | "xcode";

/** Sandbox access requires Apple-signed app provenance. Xcode uses local data only. */
export async function subscriptionEnvironment(request: Request): Promise<SubscriptionEnvironment> {
  if (!isDeployed() && process.env.FLOWCY_SUBSCRIPTION_XCODE_API_KEY && request.headers.get("x-storekit-environment") === "xcode") {
    return "xcode";
  }
  const proof = request.headers.get("x-storekit-app-transaction");
  if (!proof) return "production";
  if (proof.length > 16_384 || proof.split(".").length !== 3) throw invalidProof();
  const bundleId = "com.rxlab.summary-chip";
  // Accept signed production proofs from earlier app builds during rollout.
  for (const expectedBundle of [bundleId, `${bundleId}.Clip`]) {
    for (const apple of [Environment.SANDBOX, Environment.PRODUCTION]) {
      try {
        const key = `${expectedBundle}:${apple}`;
        let verifier = verifiers.get(key);
        if (!verifier) {
          const root = readFileSync(path.join(process.cwd(), "lib/subscription/certificates/AppleRootCA-G3.cer"));
          verifier = new SignedDataVerifier([root], true, apple, expectedBundle, 6818102153);
          verifiers.set(key, verifier);
        }
        await verifier.verifyAndDecodeAppTransaction(proof);
        return apple === Environment.SANDBOX ? "sandbox" : "production";
      } catch (error) {
        if (!(error instanceof VerificationException)) throw error;
        if (error.status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE) throw new ApiError(503, "APPLE_VERIFICATION_UNAVAILABLE", "Apple verification is unavailable. Please try again.");
        if (error.status !== VerificationStatus.INVALID_ENVIRONMENT && error.status !== VerificationStatus.INVALID_APP_IDENTIFIER) throw invalidProof();
      }
    }
  }
  throw invalidProof();
}

function invalidProof() {
  return new ApiError(403, "INVALID_STOREKIT_ENVIRONMENT", "The App Store environment could not be verified.");
}
