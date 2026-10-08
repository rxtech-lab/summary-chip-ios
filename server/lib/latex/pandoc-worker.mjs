import { parentPort, workerData } from "node:worker_threads";
import { convert } from "pandoc-wasm";

// Each export owns its own WASM filesystem and memory; concurrent readers cannot share files.
try {
  const files = Object.fromEntries(workerData.files.map((file) => [file.path, file.bytes ? new Blob([file.bytes]) : file.content]));
  const result = await convert({
    from: "latex", to: "docx", standalone: true,
    "input-files": [workerData.mainFile], "output-file": "__chippy_export.docx",
    citeproc: true,
    ...(workerData.style.enabled ? {
      "number-sections": workerData.style.sectionNumbers,
      "table-of-contents": workerData.style.tableOfContents,
      "toc-depth": workerData.style.tocDepth,
    } : {}),
    metadata: { title: workerData.title, lang: workerData.language },
  }, null, files);
  if (result.warnings.some((warning) => warning.verbosity !== "INFO")) throw new Error("Unresolved paper content");
  const output = result.files["__chippy_export.docx"];
  if (!(output instanceof Blob) || output.size === 0) throw new Error("Pandoc did not produce a Word document");
  const bytes = new Uint8Array(await output.arrayBuffer());
  parentPort.postMessage({ bytes });
} catch {
  // Never return source text, private paths or model/library diagnostics in an API error.
  parentPort.postMessage({ failed: true });
}
