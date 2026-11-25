import { z } from "zod";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { submitAppleTransaction } from "@/lib/subscription/flowcy";

export const runtime = "nodejs";
const transaction = z.object({ signedTransaction: z.string().min(16).max(100_000) }).strict();

export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, storeEnvironment }) => {
    const { signedTransaction } = await readJson(request, body => transaction.parse(body));
    await submitAppleTransaction(principal.sub, storeEnvironment, signedTransaction);
    return noStoreJson({ accepted: true });
  });
}
