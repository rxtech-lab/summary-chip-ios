import { withPublicApi } from "@/lib/http/handler";
import { notFound } from "@/lib/http/errors";
import { getObjectStore } from "@/lib/storage/r2";
export const runtime = "nodejs";
export async function GET(request: Request, { params }: { params: Promise<{ file: string }> }) {
  return withPublicApi(request, async () => {
    const { file } = await params;
    if (!/^[a-f0-9]{48}\.webp$/.test(file)) throw notFound();
    const object = await getObjectStore().get(`document-images/${file}`);
    return new Response(object.bytes as BodyInit, { headers: { "content-type": "image/webp", "cache-control": "public, max-age=31536000, immutable", "x-content-type-options": "nosniff" } });
  });
}
