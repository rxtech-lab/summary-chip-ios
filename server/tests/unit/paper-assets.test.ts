import { afterEach, describe, expect, it, vi } from "vitest";
import { MAX_PAPER_ASSET_BYTES, paperDocumentSchema, paperFileSchema, paperOperationSchema, type PaperDocument, type PaperFile } from "@/lib/contracts/paper";
import { LatexOnHttpCompiler } from "@/lib/latex/latex-on-http";
import { applyPaperOperations, paperHash, paperText } from "@/lib/services/paper-document";

const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=";
const image: PaperFile = { path: "images/example.png", content: "", asset: { key: "uploads/staged.png", mimeType: "image/png", byteSize: Buffer.from(png, "base64").length } };
const document: PaperDocument = {
  title: "Figures", mainFile: "main.tex", compiler: "pdflatex",
  files: [{ path: "main.tex", content: String.raw`\documentclass{article}
\usepackage{graphicx,tikz,pgfplots}
\pgfplotsset{compat=1.18}
\begin{document}
\includegraphics{images/example.png}
\input{figures/diagram.tikz}
\end{document}` }, image, { path: "figures/diagram.tikz", content: String.raw`\begin{tikzpicture}\draw (0,0) -- (1,1);\end{tikzpicture}` }],
};

afterEach(() => vi.unstubAllGlobals());

describe("paper assets", () => {
  it("accepts text and PNG, JPEG and PDF upload references", () => {
    expect(paperDocumentSchema.parse(document).files[1]).toEqual(image);
    for (const [path, mimeType] of [["image.jpeg", "image/jpeg"], ["figure.pdf", "application/pdf"]] as const) {
      expect(paperFileSchema.parse({ path, asset: { key: "uploads/staged", mimeType, byteSize: 100 } }).content).toBe("");
    }
    expect(paperOperationSchema.safeParse({ op: "write_file", ...image }).success).toBe(true);
  });

  it("refuses missing upload references, inline bytes and mismatched file types", () => {
    for (const bad of [
      { ...image, asset: undefined }, { ...image, content: png }, { ...image, content: `data:image/png;base64,${png}` },
      { ...image, asset: { ...image.asset, byteSize: 0 } }, { ...image, path: "main.tex" },
      { ...image, path: "figure.pdf" },
    ]) expect(paperFileSchema.safeParse(bad).success).toBe(false);
    expect(paperFileSchema.safeParse({ ...image, asset: { ...image.asset, byteSize: MAX_PAPER_ASSET_BYTES + 1 } }).success).toBe(false);
  });

  it("enforces the aggregate image limit separately from text limits", () => {
    const large = { ...image, asset: { ...image.asset, byteSize: MAX_PAPER_ASSET_BYTES } };
    expect(paperDocumentSchema.safeParse({ ...document, files: [document.files[0], large] }).success).toBe(true);
    expect(paperDocumentSchema.safeParse({ ...document, files: [document.files[0], large, { ...large, path: "images/other.png" }, { ...large, path: "images/third.png" }] }).success).toBe(false);
  });

  it("preserves S3 references on writes/renames and rejects text edits to images", () => {
    const added = applyPaperOperations({ ...document, files: [document.files[0]] }, [{ op: "write_file", ...image }]);
    expect(added.files[1]).toEqual(image);
    const renamed = applyPaperOperations(added, [{ op: "rename_file", from: image.path, to: "images/renamed.png" }]);
    expect(renamed.files[1]).toEqual({ ...image, path: "images/renamed.png" });
    expect(() => applyPaperOperations(added, [{ op: "edit_file", path: image.path, edits: [{ find: "iVBOR", replace: "x" }] }])).toThrow("Images cannot be edited as text");
    expect(() => applyPaperOperations(added, [{ op: "rename_file", from: image.path, to: "image.tex" }])).toThrow("invalid");
    expect(() => applyPaperOperations(added, [{ op: "set_main_file", path: image.path }])).toThrow("main file must be a .tex");
  });

  it("invalidates the PDF cache when only an image reference changes and excludes keys from search", () => {
    const changed = { ...document, files: [...document.files] };
    changed.files[1] = { ...image, asset: { ...image.asset!, key: "uploads/replaced.png" } };
    expect(paperHash(changed)).not.toBe(paperHash(document));
    expect(paperText(document)).not.toContain(image.asset!.key);
  });
});

describe("LaTeX asset transport", () => {
  it("sends image bytes through the provider's file field and leaves TikZ source as text", async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response("%PDF-1.4", { headers: { "content-type": "application/pdf" } }));
    vi.stubGlobal("fetch", fetchMock);
    const result = await new LatexOnHttpCompiler("https://example.test").compile({ ...document, assetData: { [image.path]: Buffer.from(png, "base64") } }, { strict: true });
    expect(result.ok).toBe(true);
    const payload = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(payload.resources).toEqual([
      { path: "main.tex", main: true, content: document.files[0].content },
      { path: image.path, file: png },
      { path: "figures/diagram.tikz", content: document.files[2].content },
    ]);
    expect(payload.options.compiler.halt_on_error).toBe(true);
  });

  it("reports missing image bytes before contacting the provider", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    await expect(new LatexOnHttpCompiler("https://example.test").compile(document)).rejects.toThrow("Image bytes are missing");
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
