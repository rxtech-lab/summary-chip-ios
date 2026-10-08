import { z } from "zod";

/** Shared PDF/Word layout controls. Disabled preserves the project's own LaTeX layout. */
export const paperRenderingSchema = z.object({
  enabled: z.boolean().default(false),
  pageSize: z.enum(["a4", "letter", "legal", "a5"]).default("a4"),
  orientation: z.enum(["portrait", "landscape"]).default("portrait"),
  columns: z.number().int().min(1).max(2).default(1),
  columnGap: z.number().min(3).max(20).default(6),
  marginTop: z.number().min(5).max(50).default(20),
  marginBottom: z.number().min(5).max(50).default(20),
  marginLeft: z.number().min(5).max(50).default(20),
  marginRight: z.number().min(5).max(50).default(20),
  fontFamily: z.enum(["original", "serif", "sans", "mono"]).default("original"),
  fontSize: z.number().min(8).max(24).default(12),
  lineSpacing: z.number().min(1).max(2.5).default(1.15),
  paragraphSpacing: z.number().min(0).max(24).default(6),
  paragraphIndent: z.number().min(0).max(36).default(0),
  alignment: z.enum(["justified", "left", "center", "right"]).default("justified"),
  headingSize: z.number().min(12).max(32).default(18),
  headingColor: z.enum(["000000", "1D4ED8", "4338CA", "0F766E", "475569"]).default("000000"),
  sectionNumbers: z.boolean().default(true),
  tableOfContents: z.boolean().default(false),
  tocDepth: z.number().int().min(1).max(3).default(2),
  titlePage: z.boolean().default(false),
  hyphenation: z.boolean().default(true),
  pageNumbers: z.enum(["none", "footer-left", "footer-center", "footer-right", "header-left", "header-center", "header-right"]).default("footer-center"),
  headerText: z.string().max(160).default(""),
  footerText: z.string().max(160).default(""),
}).strict();

export type PaperRendering = z.infer<typeof paperRenderingSchema>;
export const DEFAULT_PAPER_RENDERING = paperRenderingSchema.parse({});
