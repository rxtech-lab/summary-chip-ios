import { chatRequestSchema, sanitizeChatMessages, streamChat } from "@/lib/ai/chat";
import { withApiAuth } from "@/lib/http/handler";
import { readJson } from "@/lib/http/errors";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
export const maxDuration = 120;

export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const body = await readJson(request, (value) => chatRequestSchema.parse(value));
    const messages = sanitizeChatMessages(body.messages);
    return streamChat(db, principal.sub, messages, {
      summaryId: body.summaryId,
      localContent: body.localContent,
      billingEnvironment: await billingEnvironment(request, principal),
      abortSignal: request.signal,
    });
  });
}
