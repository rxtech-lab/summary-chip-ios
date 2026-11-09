import type { RichBlock, RichBlockAlignment, RichBlockType, RichChild, RichColumn, RichDocument } from "@/lib/contracts/rich-document";
import { MAX_RICH_BLOCKS, MAX_RICH_MARKDOWN_CHARS, RICH_BLOCK_ALIGNMENTS } from "@/lib/contracts/rich-document";

/**
 * Markdown ⇄ blocks. Spec: `docs/rich-documents.md#markdown`.
 *
 * - Text runs become text blocks; a `#` or `##` heading starts a new one, so sections stay addressable.
 * - A line holding only `![alt](https://… "caption")` is a media block: video or audio by the URL's
 *   extension, an image otherwise. Two such lines in a row (same type) become one two-column block.
 * - Lines holding only `[title](url)` right after a media block become its link children.
 * - `::: columns` / `::: center` / `::: trailing` (combinable) opens a container, `+++` starts its second
 *   column and `:::` closes it. Its columns become one block, media when each column is a media line.
 */

const VIDEO_EXTENSIONS = /\.(mp4|m4v|mov|webm|m3u8)$/i;
const AUDIO_EXTENSIONS = /\.(mp3|m4a|aac|wav|ogg|oga|flac|opus)$/i;
const MEDIA_LINE = /^!\[([^\]]*)\]\(\s*<?(https:\/\/[^\s>)]+)>?(?:\s+"([^"]*)")?\s*\)$/;
const LINK_LINE = /^\[([^\]]+)\]\(\s*<?((?:https?:\/\/|mailto:)[^\s>)]+)>?\s*\)$/;
const FENCE = /^(\s{0,3})(`{3,}|~{3,})/;
const SECTION_HEADING = /^#{1,2}\s+\S/;
const CONTAINER_OPEN = /^:::\s*([a-z][a-z\s]*)$/i;

export function mediaTypeFor(url: string): Exclude<RichBlockType, "text"> {
  const path = (() => {
    try {
      return new URL(url).pathname;
    } catch {
      return url;
    }
  })();
  if (VIDEO_EXTENSIONS.test(path)) return "video";
  if (AUDIO_EXTENSIONS.test(path)) return "audio";
  return "image";
}

interface MediaLine { type: Exclude<RichBlockType, "text">; column: RichColumn }

function parseMediaLine(line: string): MediaLine | null {
  const match = MEDIA_LINE.exec(line.trim());
  if (!match) return null;
  const [, alt, url, caption] = match;
  const type = mediaTypeFor(url);
  return { type, column: { url, alt: alt.trim() || null, caption: caption?.trim() || null } };
}

function parseLinkLine(line: string): RichChild | null {
  const match = LINK_LINE.exec(line.trim());
  return match ? { type: "link", title: match[1].trim().slice(0, 200), url: match[2] } : null;
}

/** Hands out block ids that aren't taken: b1, b2… */
export function blockIdAllocator(taken: Iterable<string>): () => string {
  const used = new Set(taken);
  let next = 1;
  return () => {
    while (used.has(`b${next}`)) next += 1;
    const id = `b${next}`;
    used.add(id);
    return id;
  };
}

/** Splits text too long for one column at paragraph breaks, so a long import still validates. */
function chunked(markdown: string): string[] {
  if (markdown.length <= MAX_RICH_MARKDOWN_CHARS) return [markdown];
  const chunks: string[] = [];
  let current = "";
  for (const paragraph of markdown.split(/\n{2,}/)) {
    for (let start = 0; start < paragraph.length || start === 0; start += MAX_RICH_MARKDOWN_CHARS) {
      const piece = paragraph.slice(start, start + MAX_RICH_MARKDOWN_CHARS);
      if (current && current.length + piece.length + 2 > MAX_RICH_MARKDOWN_CHARS) {
        chunks.push(current);
        current = "";
      }
      current = current ? `${current}\n\n${piece}` : piece;
      if (paragraph.length === 0) break;
    }
  }
  if (current) chunks.push(current);
  return chunks;
}

export interface ParsedMarkdown {
  /** The first line's `# heading`, taken out of the blocks when `takeTitle` is set. */
  title: string | null;
  blocks: RichBlock[];
}

/** Turns Markdown into blocks. Ids come from `nextId` so they don't clash with a document's others. */
export function markdownToBlocks(markdown: string, options: { nextId?: () => string; takeTitle?: boolean } = {}): ParsedMarkdown {
  const nextId = options.nextId ?? blockIdAllocator([]);
  const lines = markdown.replace(/\r\n?/g, "\n").split("\n");
  const blocks: RichBlock[] = [];
  let title: string | null = null;
  let text: string[] = [];
  let index = 0;

  const flushText = () => {
    const body = text.join("\n").replace(/^\n+|\s+$/g, "");
    text = [];
    if (!body) return;
    for (const piece of chunked(body)) blocks.push({ id: nextId(), type: "text", align: "leading", columns: [{ markdown: piece }], children: [] });
  };

  /** Link-only lines after a media block become its children. */
  const takeChildren = (block: RichBlock) => {
    let lookahead = index;
    const children: RichChild[] = [];
    while (lookahead < lines.length && children.length < 20) {
      if (!lines[lookahead].trim()) {
        lookahead += 1;
        continue;
      }
      const child = parseLinkLine(lines[lookahead]);
      if (!child) break;
      children.push(child);
      lookahead += 1;
      index = lookahead;
    }
    block.children = children;
  };

  if (options.takeTitle) {
    while (index < lines.length && !lines[index].trim()) index += 1;
    const heading = /^#\s+(.+?)\s*#*\s*$/.exec(lines[index] ?? "");
    if (heading) {
      title = heading[1].trim().slice(0, 200);
      index += 1;
    }
  }

  while (index < lines.length) {
    const line = lines[index];

    const fence = FENCE.exec(line);
    if (fence) {
      // A code block is text, whatever it holds.
      const marker = fence[2];
      text.push(line);
      index += 1;
      while (index < lines.length) {
        text.push(lines[index]);
        index += 1;
        if (lines[index - 1].trim().startsWith(marker[0].repeat(marker.length))) break;
      }
      continue;
    }

    const container = CONTAINER_OPEN.exec(line.trim());
    if (container) {
      const words = container[1].toLowerCase().split(/\s+/);
      const align = (RICH_BLOCK_ALIGNMENTS.find((alignment) => words.includes(alignment)) ?? "leading") as RichBlockAlignment;
      const columns: string[][] = [[]];
      index += 1;
      while (index < lines.length && lines[index].trim() !== ":::") {
        if (lines[index].trim() === "+++" && columns.length < 2) columns.push([]);
        else columns[columns.length - 1].push(lines[index]);
        index += 1;
      }
      index += 1; // the closing `:::`
      flushText();
      const bodies = columns.map((column) => column.join("\n").trim()).filter(Boolean);
      if (bodies.length === 0) continue;
      const media = bodies.map((body) => (body.includes("\n") ? null : parseMediaLine(body)));
      const block: RichBlock = media.every((item): item is MediaLine => item !== null && item.type === media[0]!.type)
        ? { id: nextId(), type: media[0]!.type, align, columns: media.map((item) => item.column), children: [] }
        : { id: nextId(), type: "text", align, columns: bodies.map((body) => ({ markdown: body.slice(0, MAX_RICH_MARKDOWN_CHARS) })), children: [] };
      if (block.type !== "text") takeChildren(block);
      blocks.push(block);
      continue;
    }

    const media = parseMediaLine(line);
    if (media) {
      flushText();
      const columns = [media.column];
      index += 1;
      const pair = index < lines.length ? parseMediaLine(lines[index]) : null;
      if (pair && pair.type === media.type) {
        columns.push(pair.column);
        index += 1;
      }
      const block: RichBlock = { id: nextId(), type: media.type, align: "leading", columns, children: [] };
      takeChildren(block);
      blocks.push(block);
      continue;
    }

    if (SECTION_HEADING.test(line)) flushText();
    text.push(line);
    index += 1;
  }
  flushText();
  return { title, blocks: blocks.slice(0, MAX_RICH_BLOCKS) };
}

function mediaMarkdown(column: RichColumn): string {
  const alt = (column.alt ?? column.caption ?? "").replace(/[[\]]/g, "");
  const caption = column.caption ? ` "${column.caption.replace(/"/g, "'")}"` : "";
  return `![${alt}](${column.url}${caption})`;
}

/** One block as Markdown that `markdownToBlocks` reads back as the same block (ids aside). */
export function blockToMarkdown(block: RichBlock): string {
  const columns = block.columns.map((column) => (block.type === "text" ? (column.markdown ?? "").trim() : mediaMarkdown(column)));
  const plain = columns.length === 1 && block.align === "leading";
  const words = [columns.length > 1 ? "columns" : null, block.align !== "leading" ? block.align : null].filter(Boolean).join(" ");
  const body = plain ? columns[0] : [`::: ${words}`, columns.join("\n+++\n"), ":::"].join("\n");
  const children = block.children.map((child) => `[${child.title.replace(/[[\]]/g, "")}](${child.url})`);
  return [body, ...children].join("\n");
}

/** The whole document as Markdown: its title as a `#` heading, then its blocks. */
export function documentToMarkdown(document: RichDocument, options: { includeTitle?: boolean } = {}): string {
  const parts = document.blocks.map(blockToMarkdown);
  if (options.includeTitle ?? true) parts.unshift(`# ${document.title}`);
  return `${parts.join("\n\n")}\n`;
}

/** Markdown reduced to readable text, for the card and search. */
export function plainText(markdown: string): string {
  return markdown
    .replace(/```[^\n]*\n([\s\S]*?)```/g, "$1")
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/^[ \t]{0,3}(#{1,6}|>|[-*+]|\d+[.)])[ \t]+/gm, "")
    .replace(/[*_~`]+/g, "")
    .replace(/^[ \t]*(:::.*|\+\+\+|[-*_]{3,}|\|?[ \t:-]*\|[ \t:|-]*)[ \t]*$/gm, "")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}
