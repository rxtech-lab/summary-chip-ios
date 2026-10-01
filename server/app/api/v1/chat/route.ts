import { chatRequestSchema, sanitizeChatMessages, streamChat } from "@/lib/ai/chat";
import { withApiAuth } from "@/lib/http/handler";
import { readJson } from "@/lib/http/errors";

export const runtime = "nodejs";
export const maxDuration = 120;

export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const body = await readJson(request, (value) => chatRequestSchema.parse(value));
    return streamChat(db, principal.sub, sanitizeChatMessages(body.messages), body.summaryId, body.localContent);
  });
}
