import { LatexCompilerError, LOG_TAIL_CHARS, parseLatexLog, type CompileOptions, type LatexCompiler, type LatexProject, type LatexResult } from "./compiler";

const DEFAULT_URL = "https://latex.ytotech.com";
const TIMEOUT_MS = 90_000;
const PDF_MAX_BYTES = 40 * 1024 * 1024;
/** What latex-on-http names the main resource, whatever path it was sent with. */
const MAIN_ALIAS = "__main_document__.tex";

interface FailureBody {
  error?: string;
  logs?: string;
  log_files?: Record<string, string>;
}

/**
 * YtoTech's latex-on-http (`POST /builds/sync`): a TeX Live in a container, compiling the
 * resources it is sent and answering with the PDF (2xx) or a JSON failure with the logs.
 */
export class LatexOnHttpCompiler implements LatexCompiler {
  readonly id = "latex-on-http";
  private readonly baseUrl: string;

  constructor(baseUrl = process.env.LATEX_COMPILE_URL?.trim() || DEFAULT_URL) {
    this.baseUrl = baseUrl.replace(/\/+$/, "");
  }

  async compile(project: LatexProject, options: CompileOptions = {}): Promise<LatexResult> {
    const resources = project.files.map((file) => {
      if (file.asset) {
        const bytes = project.assetData?.[file.path];
        if (!bytes) throw new LatexCompilerError(`Image bytes are missing for ${file.path}`);
        return { path: file.path, file: Buffer.from(bytes).toString("base64") };
      }
      return { ...(file.path === project.mainFile ? { main: true } : {}), path: file.path, content: file.content };
    });
    let response: Response;
    try {
      response = await fetch(`${this.baseUrl}/builds/sync`, {
        method: "POST",
        headers: { "content-type": "application/json", accept: "application/pdf, application/json" },
        body: JSON.stringify({
          compiler: project.compiler,
          resources,
          options: {
            compiler: { bibliography: true, halt_on_error: options.strict === true },
            response: { log_files_on_failure: true },
          },
        }),
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
    } catch (error) {
      throw new LatexCompilerError(`The LaTeX service could not be reached: ${(error as Error).message}`);
    }

    const contentType = response.headers.get("content-type") ?? "";
    if (response.ok && contentType.includes("application/pdf")) {
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (bytes.byteLength > PDF_MAX_BYTES) throw new LatexCompilerError("The compiled PDF is too large");
      return { ok: true, pdf: bytes };
    }

    const text = await response.text().catch(() => "");
    let body: FailureBody | null = null;
    try {
      body = JSON.parse(text) as FailureBody;
    } catch {
      body = null;
    }
    // Errors that aren't the document's (rate limits, outages) are the service's problem.
    if (!body || (body.error !== "COMPILATION_ERROR" && response.status !== 400)) {
      throw new LatexCompilerError(`The LaTeX service answered ${response.status}${body?.error ? ` (${body.error})` : ""}`);
    }
    const log = Object.values(body.log_files ?? {}).join("\n") || body.logs || "";
    const errors = parseLatexLog(log, project.mainFile, MAIN_ALIAS);
    return {
      ok: false,
      errors: errors.length ? errors : [{ file: null, line: null, message: "LaTeX produced no PDF. See the log for details." }],
      log: log.slice(-LOG_TAIL_CHARS),
    };
  }
}
