import { chatRequestSchema, sanitizeChatMessages, streamChat } from "@/lib/ai/chat";
import { requireAppFeature } from "@/lib/http/app-version";
import { withApiAuth } from "@/lib/http/handler";
import { readJson } from "@/lib/http/errors";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
export const maxDuration = 120;

export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const body = await readJson(request, (value) => chatRequestSchema.parse(value));
    if (body.tripId) requireAppFeature(request, "trips");
    const messages = sanitizeChatMessages(body.messages);
    return streamChat(db, principal.sub, messages, {
      summaryId: body.summaryId,
      localContent: body.localContent,
      tripId: body.tripId,
      billingEnvironment: await billingEnvironment(request, principal),
      abortSignal: request.signal,
    });
  });
}
