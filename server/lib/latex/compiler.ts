import type { PaperCompiler, PaperFile } from "@/lib/contracts/paper";
import { mockServicesEnabled } from "@/lib/storage/r2";

/**
 * LaTeX compilation behind one interface, so the engine can move (a hosted latex-on-http, a
 * self-hosted one, a sandbox) without touching papers. Spec: `docs/papers.md`.
 */

export interface LatexProject {
  files: PaperFile[];
  mainFile: string;
  compiler: PaperCompiler;
  /** Bytes loaded from private S3 assets for this compile; never persisted in paper JSON. */
  assetData?: Record<string, Uint8Array>;
}

/** One problem from the compile log, pointing at a project file when the log names one. */
export interface LatexIssue {
  /** A project path (`chapters/intro.tex`), or null when the log doesn't say where. */
  file: string | null;
  line: number | null;
  message: string;
}

export type LatexResult =
  | { ok: true; pdf: Uint8Array }
  | { ok: false; errors: LatexIssue[]; log: string };

export interface CompileOptions {
  /**
   * Stop at the first error and report it. Without it (live preview) TeX recovers from errors
   * the way an editor's preview does and still returns a PDF when it can.
   */
  strict?: boolean;
}

export interface LatexCompiler {
  readonly id: string;
  compile(project: LatexProject, options?: CompileOptions): Promise<LatexResult>;
}

/** The engine couldn't be reached or answered nonsense (not a LaTeX error): try again later. */
export class LatexCompilerError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "LatexCompilerError";
  }
}

/** How much of the log goes back to callers: its end, where TeX reports what stopped it. */
export const LOG_TAIL_CHARS = 6000;

const ISSUE_LINE = /^(?:\.\/)?(.+?\.[A-Za-z0-9]+):(\d+): (.+)$/;

/**
 * The errors of a `file:line:error` style log (`./chapters/intro.tex:2: Undefined control
 * sequence.`), and `! …` errors without a location. `mainAlias` is the name the engine gave the
 * main file (latex-on-http calls it `__main_document__.tex`); it is reported as `mainFile`.
 */
export function parseLatexLog(log: string, mainFile: string, mainAlias?: string): LatexIssue[] {
  const issues: LatexIssue[] = [];
  const seen = new Set<string>();
  const add = (issue: LatexIssue) => {
    const key = `${issue.file}:${issue.line}:${issue.message}`;
    if (seen.has(key) || issues.length >= 20) return;
    seen.add(key);
    issues.push(issue);
  };
  for (const raw of log.split(/\r?\n/)) {
    const line = raw.trimEnd();
    const located = ISSUE_LINE.exec(line);
    if (located) {
      const message = located[3].trim();
      // TeX's closing remark repeats the error that stopped it.
      if (/^==> Fatal error occurred/.test(message)) continue;
      const file = located[1] === mainAlias ? mainFile : located[1];
      add({ file, line: Number(located[2]), message });
    } else if (line.startsWith("! ")) {
      add({ file: null, line: null, message: line.slice(2).trim() });
    }
  }
  // Errors with a place say more than the same error without one.
  const located = issues.filter((issue) => issue.file !== null);
  return located.length ? located : issues;
}

let override: LatexCompiler | undefined;

export function setLatexCompilerForTests(compiler?: LatexCompiler): void {
  override = compiler;
}

/**
 * `LATEX_COMPILER` picks one: latex-on-http at `LATEX_COMPILE_URL` by default (the hosted
 * `https://latex.ytotech.com`, or a self-hosted instance), `mock` for development.
 */
export async function getLatexCompiler(): Promise<LatexCompiler> {
  if (override) return override;
  if (process.env.LATEX_COMPILER?.trim() === "mock" || mockServicesEnabled()) {
    const { MockLatexCompiler } = await import("./mock");
    return new MockLatexCompiler();
  }
  const { LatexOnHttpCompiler } = await import("./latex-on-http");
  return new LatexOnHttpCompiler();
}
