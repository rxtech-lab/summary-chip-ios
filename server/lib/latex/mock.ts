import type { CompileOptions, LatexCompiler, LatexProject, LatexResult } from "./compiler";

/** The smallest valid one-page PDF, so clients can render the mock's output. */
const BLANK_PDF = `%PDF-1.4
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 595 842]>>endobj
trailer<</Root 1 0 R>>
%%EOF
`;

/**
 * Development and tests: "compiles" every project into a blank page, except that a line with
 * `\\undefinedcommand` is reported as an error at that file and line. Counts its calls.
 */
export class MockLatexCompiler implements LatexCompiler {
  readonly id = "mock";
  calls: { project: LatexProject; options: CompileOptions }[] = [];

  async compile(project: LatexProject, options: CompileOptions = {}): Promise<LatexResult> {
    this.calls.push({ project, options });
    for (const file of project.files) {
      const index = file.content.split("\n").findIndex((line) => line.includes("\\undefinedcommand"));
      if (index >= 0) {
        return {
          ok: false,
          errors: [{ file: file.path, line: index + 1, message: "Undefined control sequence." }],
          log: `./${file.path}:${index + 1}: Undefined control sequence.\nl.${index + 1} \\undefinedcommand`,
        };
      }
    }
    return { ok: true, pdf: new TextEncoder().encode(BLANK_PDF) };
  }
}
