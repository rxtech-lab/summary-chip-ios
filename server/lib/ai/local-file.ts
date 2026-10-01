import { tool } from "ai";
import { z } from "zod";

/** Files at most this long are inlined into the instructions whole; longer ones get an opening preview. */
export const LOCAL_INLINE_LIMIT = 20_000;
const MAX_MATCHES = 50;
const MAX_CONTEXT_LINES = 5;
const MAX_READ_LINES = 400;
const MAX_READ_CHARS = 30_000;
/** Lines are clipped before matching and in results, so one huge line can't stall or flood the model. */
const MAX_LINE_CHARS = 2_000;

export type LocalFileMatch = { line: number; text: string; before?: string[]; after?: string[] };

export function splitLines(content: string): string[] {
  return content.split(/\r\n|\r|\n/);
}

function clip(line: string): string {
  return line.length > MAX_LINE_CHARS ? `${line.slice(0, MAX_LINE_CHARS)} […]` : line;
}

/** Rejects nested quantifiers like `(a+)+`, the usual catastrophic-backtracking shape. */
function isRiskyPattern(pattern: string): boolean {
  return /\([^()]*[+*}][^()]*\)\s*[+*{]/.test(pattern);
}

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function grepLines(
  lines: string[],
  input: { pattern: string; regex?: boolean; caseSensitive?: boolean; contextLines?: number; maxMatches?: number },
): { matches: LocalFileMatch[]; totalMatches: number; truncated: boolean } | { error: string } {
  if (input.regex && isRiskyPattern(input.pattern)) {
    return { error: "That pattern has nested repetition; use a simpler one." };
  }
  let matcher: RegExp;
  try {
    matcher = new RegExp(input.regex ? input.pattern : escapeRegExp(input.pattern), input.caseSensitive ? "u" : "iu");
  } catch {
    return { error: "Invalid regular expression." };
  }
  const context = Math.min(input.contextLines ?? 0, MAX_CONTEXT_LINES);
  const limit = Math.min(input.maxMatches ?? 20, MAX_MATCHES);
  const matches: LocalFileMatch[] = [];
  let totalMatches = 0;
  for (const [index, line] of lines.entries()) {
    if (!matcher.test(clip(line))) continue;
    totalMatches += 1;
    if (matches.length >= limit) continue;
    const match: LocalFileMatch = { line: index + 1, text: clip(line) };
    if (context > 0) {
      match.before = lines.slice(Math.max(0, index - context), index).map(clip);
      match.after = lines.slice(index + 1, index + 1 + context).map(clip);
    }
    matches.push(match);
  }
  return { matches, totalMatches, truncated: totalMatches > matches.length };
}

export function readLines(lines: string[], startLine: number, endLine?: number) {
  const totalLines = lines.length;
  if (startLine > totalLines) return { error: `The file has only ${totalLines} lines.`, totalLines };
  const last = Math.min(endLine ?? startLine + 99, startLine + MAX_READ_LINES - 1, totalLines);
  if (last < startLine) return { error: "endLine must not be before startLine.", totalLines };
  const output: string[] = [];
  let chars = 0;
  let end = startLine - 1;
  for (let number = startLine; number <= last; number += 1) {
    const text = `${number}: ${clip(lines[number - 1])}`;
    if (output.length > 0 && chars + text.length > MAX_READ_CHARS) break;
    output.push(text);
    chars += text.length + 1;
    end = number;
  }
  return { startLine, endLine: end, totalLines, text: output.join("\n"), truncated: end < last };
}

/** Grep and line-range reads over the owner's local file, sent from their device for this request only. */
export function localFileTools(content: string) {
  const lines = splitLines(content);
  return {
    grepLocalFile: tool({
      description: "Search the user's local file line by line (like grep). Returns matching lines with their 1-based line numbers, most useful for finding where something is mentioned before reading around it with readLocalFile.",
      inputSchema: z.object({
        pattern: z.string().min(1).max(200).describe("Text to find. Matched literally unless regex is true."),
        regex: z.boolean().default(false).describe("Treat pattern as a JavaScript regular expression, e.g. \"revenue|income\"."),
        caseSensitive: z.boolean().default(false),
        contextLines: z.number().int().min(0).max(MAX_CONTEXT_LINES).default(0).describe("Lines of context to include before and after each match."),
        maxMatches: z.number().int().min(1).max(MAX_MATCHES).default(20),
      }),
      execute: async (input) => ({ totalLines: lines.length, ...grepLines(lines, input) }),
    }),
    readLocalFile: tool({
      description: `Read a range of lines (1-based, inclusive) from the user's local file. Returns up to ${MAX_READ_LINES} lines prefixed with their numbers.`,
      inputSchema: z.object({
        startLine: z.number().int().min(1),
        endLine: z.number().int().min(1).optional().describe("Defaults to startLine + 99."),
      }),
      execute: async ({ startLine, endLine }) => readLines(lines, startLine, endLine),
    }),
  };
}
