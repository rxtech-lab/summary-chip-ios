import path from "node:path";
import { Worker } from "node:worker_threads";
import type { LatexProject } from "./compiler";
import { ApiError } from "@/lib/http/errors";
import { wordResources } from "./word-resources";
import { paperRenderingSchema, type PaperRendering } from "@/lib/contracts/paper-rendering";
import { renderWord } from "./word-rendering";

export const DOCX_MIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document";

/** Real Pandoc in a terminable worker; it only sees explicitly supplied paper files. */
export function paperWord(project: LatexProject & { title: string; language: string }, style: PaperRendering = paperRenderingSchema.parse({})): Promise<Uint8Array> {
  if (project.files.some((file) => /\\begin\{(?:tikzpicture|axis)\}/.test(file.content))) {
    throw new ApiError(422, "WORD_UNSUPPORTED_FIGURE", "Word export requires TikZ and plot diagrams to be replaced with images. Export PDF to keep these diagrams.");
  }
  return new Promise((resolve, reject) => {
    const worker = new Worker(path.join(process.cwd(), "lib/latex/pandoc-worker.mjs"), {
      execArgv: [],
      workerData: {
        title: project.title, language: project.language, style, ...wordResources(project),
      },
    });
    const timer = setTimeout(() => finish(new ApiError(504, "WORD_EXPORT_TIMEOUT", "Word export took too long. Please try again.")), 90_000);
    let finished = false;
    const finish = (error?: Error, bytes?: Uint8Array) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      void worker.terminate();
      if (error) reject(error);
      else resolve(bytes!);
    };
    worker.once("message", (result: { bytes?: Uint8Array; failed?: boolean }) => {
      if (!result.bytes || result.bytes.byteLength > 40 * 1024 * 1024) {
        finish(new ApiError(422, "WORD_EXPORT_FAILED", "The paper could not be converted to Word. Check its LaTeX, images and references, or export PDF."));
      } else {
        try { finish(undefined, renderWord(result.bytes, style)); }
        catch { finish(new ApiError(422, "WORD_EXPORT_FAILED", "The Word document could not be styled. Try changing the rendering options.")); }
      }
    });
    worker.once("error", () => finish(new ApiError(503, "WORD_EXPORT_UNAVAILABLE", "Word export is unavailable right now. Please try again.")));
    worker.once("exit", (code) => { if (code !== 0) finish(new ApiError(503, "WORD_EXPORT_UNAVAILABLE", "Word export stopped before finishing. Please try again.")); });
  });
}
