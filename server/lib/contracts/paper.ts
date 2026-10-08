import { z } from "zod";

/**
 * A LaTeX paper: source files and image assets compiled from `mainFile` into one PDF.
 * Spec: `docs/papers.md`. `Packages/SummaryKit/Sources/SummaryKit/Models/Paper.swift` mirrors it.
 */

export const PAPER_COMPILERS = ["pdflatex", "xelatex", "lualatex"] as const;
export type PaperCompiler = (typeof PAPER_COMPILERS)[number];

export const PAPER_EXPORT_FORMATS = ["pdf", "docx"] as const;
export type PaperExportFormat = (typeof PAPER_EXPORT_FORMATS)[number];

/** Text files a LaTeX project is made of. */
export const PAPER_FILE_EXTENSIONS = [
  "tex", "bib", "sty", "cls", "bst", "bbx", "cbx", "lbx", "def", "cfg", "clo", "ist", "tikz", "txt", "csv", "tsv", "dat", "md",
] as const;
export const PAPER_IMAGE_EXTENSIONS = ["png", "jpg", "jpeg", "pdf"] as const;

export const MAX_PAPER_FILES = 60;
export const MAX_PAPER_FILE_CHARS = 400_000;
/** Text source limits are independent of image bytes. */
export const MAX_PAPER_TOTAL_CHARS = 800_000;
export const MAX_PAPER_ASSET_BYTES = 10 * 1024 * 1024;
export const MAX_PAPER_TOTAL_ASSET_BYTES = 25 * 1024 * 1024;
export const MAX_PAPER_TITLE_CHARS = 200;

/** `chapters/intro.tex`: relative, `/`-separated, no `..`, an allowed extension. */
const PATH_PATTERN = /^(?:[A-Za-z0-9_-][A-Za-z0-9._-]*\/){0,4}[A-Za-z0-9_-][A-Za-z0-9._-]*\.([A-Za-z0-9]+)$/;

export const paperPathSchema = z.string().trim().min(1).max(160).superRefine((path, context) => {
  const match = PATH_PATTERN.exec(path);
  if (!match || path.split("/").some((part) => part === "." || part === "..")) {
    context.addIssue({ code: "custom", message: "Use a relative path like chapters/intro.tex (letters, digits, . _ -, at most 5 folders)" });
    return;
  }
  if (!([...PAPER_FILE_EXTENSIONS, ...PAPER_IMAGE_EXTENSIONS] as readonly string[]).includes(match[1].toLowerCase())) {
    context.addIssue({ code: "custom", message: `Files must end in .${[...PAPER_FILE_EXTENSIONS, ...PAPER_IMAGE_EXTENSIONS].join(", .")}` });
  }
});

export const paperAssetSchema = z.object({
  key: z.string().min(1).max(512),
  mimeType: z.enum(["image/png", "image/jpeg", "application/pdf"]),
  byteSize: z.number().int().positive().max(MAX_PAPER_ASSET_BYTES),
});
export type PaperAsset = z.infer<typeof paperAssetSchema>;

export const paperFileSchema = z.object({
  path: paperPathSchema,
  content: z.string().max(MAX_PAPER_FILE_CHARS).default(""),
  /** Image bytes live in S3, never in the working copy or version JSON. */
  asset: paperAssetSchema.optional(),
}).superRefine((file, context) => {
  const extension = file.path.split(".").at(-1)?.toLowerCase() ?? "";
  const image = (PAPER_IMAGE_EXTENSIONS as readonly string[]).includes(extension);
  if (!image) {
    if (file.asset) context.addIssue({ code: "custom", path: ["asset"], message: "Text source files cannot reference an image asset" });
    return;
  }
  if (!file.asset) {
    context.addIssue({ code: "custom", path: ["asset"], message: "PNG, JPEG and PDF assets require an S3 upload reference" });
    return;
  }
  if (file.content) context.addIssue({ code: "custom", path: ["content"], message: "Image bytes must be uploaded to S3; leave content empty" });
  const mimeType = extension === "png" ? "image/png" : extension === "pdf" ? "application/pdf" : "image/jpeg";
  if (file.asset.mimeType !== mimeType) context.addIssue({ code: "custom", path: ["asset", "mimeType"], message: "The image MIME type must match its file extension" });
});

export type PaperFile = z.infer<typeof paperFileSchema>;

export const paperTitleSchema = z.string().trim().min(1).max(MAX_PAPER_TITLE_CHARS);

/** Everything a version keeps of a paper: its title and source. */
export const paperDocumentSchema = z.object({
  title: paperTitleSchema,
  files: z.array(paperFileSchema).min(1).max(MAX_PAPER_FILES),
  mainFile: paperPathSchema,
  compiler: z.enum(PAPER_COMPILERS).default("pdflatex"),
}).superRefine((document, context) => {
  const seen = new Set<string>();
  document.files.forEach((file, index) => {
    if (seen.has(file.path)) context.addIssue({ code: "custom", path: ["files", index, "path"], message: `"${file.path}" is listed twice` });
    seen.add(file.path);
  });
  if (!seen.has(document.mainFile)) context.addIssue({ code: "custom", path: ["mainFile"], message: `The main file "${document.mainFile}" is not one of the files` });
  else if (!document.mainFile.toLowerCase().endsWith(".tex")) context.addIssue({ code: "custom", path: ["mainFile"], message: "The main file must be a .tex file" });
  const total = document.files.reduce((sum, file) => sum + file.content.length, 0);
  if (total > MAX_PAPER_TOTAL_CHARS) context.addIssue({ code: "custom", path: ["files"], message: `The files hold ${total} characters; at most ${MAX_PAPER_TOTAL_CHARS} in all` });
  const assetBytes = document.files.reduce((sum, file) => sum + (file.asset?.byteSize ?? 0), 0);
  if (assetBytes > MAX_PAPER_TOTAL_ASSET_BYTES) context.addIssue({ code: "custom", path: ["files"], message: "The paper's images together are limited to 25 MB" });
});

export type PaperDocument = z.infer<typeof paperDocumentSchema>;

export const createPaperSchema = z.object({
  /** Without a title, the main file's `\title{…}` names the paper. */
  title: paperTitleSchema.optional(),
  files: z.array(paperFileSchema).min(1).max(MAX_PAPER_FILES).optional(),
  mainFile: paperPathSchema.optional(),
  compiler: z.enum(PAPER_COMPILERS).optional(),
  /** A starting project when `files` is left out. */
  template: z.enum(["article", "report", "blank"]).optional(),
  visibility: z.enum(["public", "private"]).default("private"),
});

/** `PUT /api/v1/papers/:id`: the app's autosave of the whole working copy. */
export const putPaperSchema = z.object({
  title: paperTitleSchema,
  files: z.array(paperFileSchema).min(1).max(MAX_PAPER_FILES),
  mainFile: paperPathSchema,
  compiler: z.enum(PAPER_COMPILERS),
  /** The revision the client edited. A mismatch returns 409 PAPER_REVISION_CONFLICT. */
  revision: z.number().int().min(0),
});

export const paperEditSchema = z.object({
  find: z.string().min(1).max(MAX_PAPER_FILE_CHARS).describe("Exact text to find in the file, including whitespace."),
  replace: z.string().max(MAX_PAPER_FILE_CHARS).describe("The text to put in its place."),
  all: z.boolean().optional().describe("Replace every occurrence. Without it, find must occur exactly once."),
});

export const paperOperationSchema = z.discriminatedUnion("op", [
  paperFileSchema.safeExtend({ op: z.literal("write_file") })
    .describe("Create or replace a file. Images use asset: {key, mimeType, byteSize} from create_upload; leave content empty."),
  z.object({ op: z.literal("edit_file"), path: paperPathSchema, edits: z.array(paperEditSchema).min(1).max(50) })
    .describe("Find-and-replace edits applied in order to an existing file."),
  z.object({ op: z.literal("delete_file"), path: paperPathSchema }).describe("Remove a file (not the main file)."),
  z.object({ op: z.literal("rename_file"), from: paperPathSchema, to: paperPathSchema }).describe("Move a file; the main file follows."),
  z.object({ op: z.literal("set_main_file"), path: paperPathSchema }).describe("The .tex file compilation starts from."),
  z.object({ op: z.literal("set_compiler"), compiler: z.enum(PAPER_COMPILERS) }).describe("pdflatex, xelatex (system fonts, CJK) or lualatex."),
  z.object({ op: z.literal("set_title"), title: paperTitleSchema }).describe("The paper's title in the library."),
]);

export type PaperOperation = z.infer<typeof paperOperationSchema>;

export const paperOperationsRequestSchema = z.object({
  operations: z.array(paperOperationSchema).min(1).max(100),
  revision: z.number().int().min(0).nullish(),
});

/**
 * Reference checks (`docs/papers.md` → References). Each bibliography entry is checked once per
 * content: a link that doesn't open, a work that can't be found, an unreliable source, a link to
 * something else, or a citation the work doesn't support is a reference error.
 */
export const PAPER_REFERENCE_STATUSES = ["unchecked", "checking", "verified", "error"] as const;
export type PaperReferenceStatus = (typeof PAPER_REFERENCE_STATUSES)[number];

export const PAPER_REFERENCE_ISSUES = ["link_not_found", "reference_not_found", "unreliable_source", "link_mismatch", "misreference"] as const;
export type PaperReferenceIssue = (typeof PAPER_REFERENCE_ISSUES)[number];

/** One bibliography entry of the working copy with its check. */
export interface PaperReference {
  /** The citation key: `\cite{key}`. */
  key: string;
  /** Where the entry is: a `.bib` file or the `.tex` file with `\bibitem`. */
  file: string;
  line: number;
  /** The entry's title (or its text, for a `\bibitem`) as plain text. */
  title: string | null;
  /** The entry's `url`, or its DOI as a doi.org link. */
  url: string | null;
  status: PaperReferenceStatus;
  /** Set when `status` is `error`. */
  issue: PaperReferenceIssue | null;
  /** What the check found: why it's an error, or what confirmed it. */
  message: string | null;
  checkedAt: string | null;
}
