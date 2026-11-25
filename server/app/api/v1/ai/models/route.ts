import { eq } from "drizzle-orm";
import { z } from "zod";
import { flowcyChatModels } from "@/lib/ai/flowcy";
import { readModelPreference } from "@/lib/ai/model-preference";
import { users } from "@/lib/db/schema";
import { ApiError, noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";

const selection = z.object({ modelId: z.string().trim().min(1).max(200).nullable() });

export async function GET(request: Request) {
  return withApiAuth(request, async ({ db, principal }) => {
    const [models, selectedModelId] = await Promise.all([
      flowcyChatModels(request.headers.get("authorization")!, request.signal),
      readModelPreference(db, principal.sub),
    ]);
    return noStoreJson({ models, selectedModelId });
  }, { requireSubscription: true });
}

export async function PUT(request: Request) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { modelId } = await readJson(request, value => selection.parse(value));
    if (modelId !== null) {
      const models = await flowcyChatModels(request.headers.get("authorization")!, request.signal);
      if (!models.some(model => model.modelId === modelId)) throw new ApiError(422, "FLOWCY_MODEL_UNAVAILABLE", "Choose an enabled Flowcy chat model.");
    }
    await db.update(users).set({ aiModelId: modelId }).where(eq(users.id, principal.sub));
    return noStoreJson({ selectedModelId: modelId });
  }, { requireSubscription: true });
}
