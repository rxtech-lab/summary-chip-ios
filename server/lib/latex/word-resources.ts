import path from "node:path";
import type { LatexProject } from "./compiler";

/** Pandoc WASM's virtual filesystem supports root files; give nested resources private flat aliases. */
export function wordResources(project: LatexProject) {
  const aliases = new Map(project.files.map((file, index) => [file.path, `resource-${index}.${file.path.split(".").at(-1)}`]));
  const reference = (sourcePath: string, value: string, extension: string) => {
    const trimmed = value.trim();
    const candidates = [trimmed, trimmed + extension, path.posix.join(path.posix.dirname(sourcePath), trimmed), path.posix.join(path.posix.dirname(sourcePath), trimmed + extension)];
    for (const candidate of candidates) if (aliases.has(candidate)) return aliases.get(candidate)!;
    return value;
  };
  return {
    mainFile: aliases.get(project.mainFile)!,
    files: project.files.map((file) => ({
      path: aliases.get(file.path)!,
      bytes: project.assetData?.[file.path],
      content: file.content
        .replace(/(\\(?:input|include)\s*\{)([^}]+)(\})/g, (_, before, value, after) => before + reference(file.path, value, ".tex") + after)
        .replace(/(\\includegraphics\*?(?:\[[^\]]*\])?\s*\{)([^}]+)(\})/g, (_, before, value, after) => {
          const resolved = ["", ".png", ".jpg", ".jpeg", ".pdf"].map((ext) => reference(file.path, value, ext)).find((resolved) => resolved !== value) ?? value;
          return before + resolved + after;
        })
        .replace(/(\\(?:bibliography|addbibresource)\s*\{)([^}]+)(\})/g, (_, before, value: string, after) => before + value.split(",").map((item) => reference(file.path, item, ".bib")).join(",") + after),
    })),
  };
}
