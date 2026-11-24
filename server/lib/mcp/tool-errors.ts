import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import { ApiError } from "@/lib/http/errors";
import type { SummaryJson } from "@/lib/services/serialize";

export function failure(message: string): CallToolResult {
  return { content: [{ type: "text", text: message }], isError: true };
}

export function toolErrorResult(error: unknown): CallToolResult {
  const result = failure(describe(error));
  if (error instanceof ApiError && error.code === "RESUME_REVISION_CONFLICT") {
    result.structuredContent = { error: { code: error.code, message: error.message, details: error.details } };
    result.content.push({ type: "text", text: JSON.stringify(result.structuredContent) });
  }
  return result;
}

function describe(error: unknown): string {
  if (error instanceof ApiError) {
    if (error.code === "DUPLICATE_SUMMARY") {
      const details = error.details as { reason?: string; duplicate?: SummaryJson } | undefined;
      let message = "Not added: this chip is already in the library";
      if (details?.duplicate) message += ` as "${details.duplicate.title}" (${details.duplicate.shareUrl})`;
      message += ".";
      if (details?.reason) message += ` Reason: ${details.reason}`;
      return `${message} Call add_summary again with allowDuplicate: true to save it anyway.`;
    }
    if (error.code === "PAPER_REVISION_CONFLICT") return `${error.message} Call get_paper for the latest files, then update_paper again. (${error.code})`;
    if (error.code === "LATEX_COMPILE_FAILED") {
      const details = error.details as { errors?: { file: string | null; line: number | null; message: string }[] } | undefined;
      const listed = (details?.errors ?? []).map((issue) => `${issue.file ?? "?"}${issue.line ? `:${issue.line}` : ""}: ${issue.message}`).join("\n");
      return `LaTeX could not compile the paper (${error.code}).${listed ? `\n${listed}` : ""}`;
    }
    if (error.code === "MINI_APP_INVALID") return `${error.message}: ${JSON.stringify(error.details)}. Use validate_mini_app to repair the definition.`;
    if (error.code === "MINI_RECORD_INVALID" && error.details) return `${error.message}. Fields: ${JSON.stringify((error.details as { fields?: unknown }).fields)}. Only declared fields are allowed; required ones must be set.`;
    if (error.code === "MINI_REVISION_CONFLICT") return `${error.message} Call get_mini_app, then update_mini_app with its revision.`;
    if (error.code === "RICH_DOCUMENT_REVISION_CONFLICT") return `${error.message} Call get_rich_document for the latest document, then update_rich_document again. (${error.code})`;
    if (error.code === "RICH_DOCUMENT_INVALID" && error.details) return `${error.message} Issues: ${JSON.stringify((error.details as { issues?: unknown }).issues)}. Fix them and call the tool again. (${error.code})`;
    if (error.code === "GRAPH_REVISION_CONFLICT") return `${error.message} Call get_graph for the latest document, then update_graph again. (${error.code})`;
    if (error.code === "TRIP_REVISION_CONFLICT") return `${error.message} Call get_trip for the latest document, then update_trip again. (${error.code})`;
    return `${error.message} (${error.code})`;
  }
  if (error instanceof z.ZodError) {
    // Named as the tool's arguments: the import schema calls key points `highlights`.
    const argument = (path: PropertyKey[]) => path.map((part) => (part === "highlights" ? "keyPoints" : String(part))).join(".") || "arguments";
    return error.issues.slice(0, 3).map((issue) => `Invalid ${argument(issue.path)}: ${issue.message}`).join("; ");
  }
  console.error("[mcp] tool failed", error);
  return "An unexpected error occurred. Please try again.";
}
