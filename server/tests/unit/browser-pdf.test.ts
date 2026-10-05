import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { renderPdf } from "@/lib/pdf/browser-pdf";

const page = { headerTemplate: "", footerTemplate: "", margin: { top: "22mm", bottom: "18mm", left: "16mm", right: "16mm" } };

beforeEach(() => {
  vi.stubEnv("CLOUDFLARE_ACCOUNT_ID", "test-account");
  vi.stubEnv("CLOUDFLARE_API_TOKEN", "test-token");
});
afterEach(() => {
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
});

describe("PDF response downloads", () => {
  it("reports a socket closing after headers as PDF_RENDER_FAILED", async () => {
    let reads = 0;
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (reads++ === 0) controller.enqueue(new TextEncoder().encode("%PDF-1.7 partial"));
        else controller.error(new TypeError("terminated", { cause: { code: "UND_ERR_SOCKET" } }));
      },
    });
    vi.stubGlobal("fetch", vi.fn(async () => new Response(body)));
    await expect(renderPdf("<html><body>Trip</body></html>", page)).rejects.toMatchObject({ status: 502, code: "PDF_RENDER_FAILED" });
  });

  it("cancels an oversized declared response without reading it", async () => {
    const cancel = vi.fn();
    const body = new ReadableStream<Uint8Array>({ cancel });
    vi.stubGlobal("fetch", vi.fn(async () => new Response(body, { headers: { "content-length": String(134_169_904) } })));
    await expect(renderPdf("<html></html>", page)).rejects.toMatchObject({ status: 502, code: "PDF_RENDER_FAILED", message: expect.stringContaining("too large") });
    expect(cancel).toHaveBeenCalledOnce();
  });

  it("bounds responses without a content length and cancels the stream", async () => {
    const cancel = vi.fn();
    const chunk = new Uint8Array(8 * 1024 * 1024);
    const body = new ReadableStream<Uint8Array>({ pull(controller) { controller.enqueue(chunk); }, cancel });
    vi.stubGlobal("fetch", vi.fn(async () => new Response(body)));
    await expect(renderPdf("<html></html>", page)).rejects.toMatchObject({ status: 502, message: expect.stringContaining("too large") });
    expect(cancel).toHaveBeenCalledOnce();
  });

  it("returns complete PDF bytes", async () => {
    const bytes = new TextEncoder().encode("%PDF-1.7 report\n%%EOF");
    vi.stubGlobal("fetch", vi.fn(async () => new Response(bytes)));
    expect(await renderPdf("<html></html>", page)).toEqual(bytes);
  });

  it("rejects non-PDF success responses", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => Response.json({ success: false })));
    await expect(renderPdf("<html></html>", page)).rejects.toMatchObject({ status: 502, code: "PDF_RENDER_FAILED" });
  });

  it("reports a failed connection as PDF_RENDER_FAILED", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => { throw new TypeError("fetch failed"); }));
    await expect(renderPdf("<html></html>", page)).rejects.toMatchObject({ status: 502, code: "PDF_RENDER_FAILED" });
  });
});
