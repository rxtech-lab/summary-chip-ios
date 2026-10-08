import { z } from "zod";
import { TRANSLATION_LANGUAGES } from "@/lib/contracts/api";
import { PAPER_EXPORT_FORMATS } from "@/lib/contracts/paper";
import { withApiAuth } from "@/lib/http/handler";
import { exportPaper } from "@/lib/services/paper-export";
import { paperRenderingSchema } from "@/lib/contracts/paper-rendering";
import { readJson } from "@/lib/http/errors";

export const runtime = "nodejs";
export const maxDuration = 120;

const querySchema = z.object({
  format: z.enum(PAPER_EXPORT_FORMATS).default("pdf"),
  lang: z.enum(["original", ...TRANSLATION_LANGUAGES]).optional(),
  version: z.coerce.number().int().positive().optional(),
});
const bodySchema = querySchema.extend({ rendering: paperRenderingSchema.optional() }).strict();

function response(output: Awaited<ReturnType<typeof exportPaper>>, format: string): Response {
  return new Response(output.bytes as BodyInit, {
    headers: {
      "content-type": output.contentType,
      "content-disposition": `attachment; filename="paper.${format}"; filename*=UTF-8''${encodeURIComponent(output.filename)}`,
      "content-language": output.language,
      "cache-control": "no-store",
      ...(output.revision === null ? {} : { "x-paper-revision": String(output.revision) }),
    },
  });
}

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const query = querySchema.parse(Object.fromEntries(new URL(request.url).searchParams));
    const output = await exportPaper(db, id, principal.sub, { format: query.format, language: query.lang, version: query.version });
    return response(output, query.format);
  }, { feature: "papers" });
}

/** Optional per-export layout override without changing the paper's saved settings. */
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const input = await readJson(request, (body) => bodySchema.parse(body));
    const output = await exportPaper(db, id, principal.sub, { format: input.format, language: input.lang, version: input.version, rendering: input.rendering });
    return response(output, input.format);
  }, { feature: "papers" });
}
