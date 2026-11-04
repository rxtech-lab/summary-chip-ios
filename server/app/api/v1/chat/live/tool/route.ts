import { requireAppFeature } from "@/lib/http/app-version";
import { voiceToolCatalog } from "@/lib/ai/live-tools";
import { asSchema, type ToolSet } from "ai";
import { z } from "zod";
import { prepareChat, chatRequestSchema } from "@/lib/ai/chat";
import { withApiAuth } from "@/lib/http/handler";
import { ApiError, readJson } from "@/lib/http/errors";

export const runtime = "nodejs";
export const maxDuration = 120;
const schema = z.object({ context: chatRequestSchema, name: z.string().min(1).max(100), callId: z.string().min(1).max(200), input: z.unknown() });
export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const body = await readJson(request, value => schema.parse(value));
    if (body.context.tripId) requireAppFeature(request, "trips");
    const prepared = await prepareChat(db, principal.sub, body.context);
    const tools = voiceToolCatalog(prepared.tools);
    const tool = Object.hasOwn(tools, body.name) ? (tools as ToolSet)[body.name] : undefined;
    if (!tool?.execute) throw new ApiError(400, "INVALID_TOOL", "This tool is not available in this context.");
    let argumentsValue = body.input;
    if (argumentsValue && typeof argumentsValue === "object" && "argumentsJson" in argumentsValue) {
      const encoded = z.object({ argumentsJson: z.string().max(1_000_000) }).strict().parse(argumentsValue);
      try { argumentsValue = JSON.parse(encoded.argumentsJson); }
      catch { throw new ApiError(400, "INVALID_INPUT", "Tool argumentsJson must contain a valid JSON object."); }
    }
    const validator = asSchema(tool.inputSchema).validate;
    // JSON-schema tools validate domain payloads inside execute, as in text chat.
    const input = validator ? await validator(argumentsValue) : { success: true as const, value: z.record(z.string(), z.unknown()).parse(argumentsValue) };
    if (!input.success) throw new ApiError(400, "INVALID_INPUT", "Invalid tool arguments.");
    const output = await tool.execute(input.value, { toolCallId: body.callId, messages: [], context: {}, abortSignal: request.signal });
    return Response.json({ output }, { headers: { "Cache-Control": "no-store" } });
  });
}
