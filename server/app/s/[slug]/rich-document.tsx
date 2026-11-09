import type { ComponentProps, ElementType } from "react";
import Markdown, { type Components } from "react-markdown";
import remarkGfm from "remark-gfm";
import type { RichBlock, RichBlockAlignment, RichColumn, RichDocument } from "@/lib/contracts/rich-document";

/**
 * A rich document on the share page: blocks top to bottom, one or two columns each (stacked on narrow
 * screens). Markdown renders without raw HTML, so an agent-written document can't inject markup.
 */

const ALIGN: Record<RichBlockAlignment, { text: string; items: string; justify: string }> = {
  leading: { text: "text-left", items: "items-start", justify: "justify-start" },
  center: { text: "text-center", items: "items-center", justify: "justify-center" },
  trailing: { text: "text-right", items: "items-end", justify: "justify-end" },
};

const external = { target: "_blank", rel: "noopener noreferrer nofollow" } as const;

/** A Markdown element with fixed styling; react-markdown's `node` prop isn't passed to the DOM. */
function styled<Tag extends "h2" | "h3" | "h4" | "h5" | "p" | "ul" | "ol" | "blockquote" | "pre" | "th" | "td">(Element: Tag, className: string) {
  return function StyledElement({ node, ...props }: ComponentProps<Tag> & { node?: unknown }) {
    void node;
    const Rendered = Element as ElementType;
    return <Rendered className={className} {...props} />;
  };
}

const markdownComponents: Components = {
  h1: styled("h2", "mt-8 text-2xl font-semibold tracking-tight first:mt-0"),
  h2: styled("h3", "mt-7 text-xl font-semibold tracking-tight first:mt-0"),
  h3: styled("h4", "mt-6 text-lg font-semibold first:mt-0"),
  h4: styled("h5", "mt-5 font-semibold first:mt-0"),
  p: styled("p", "mt-4 leading-relaxed first:mt-0"),
  ul: styled("ul", "mt-4 list-disc space-y-1 ps-6 text-start first:mt-0"),
  ol: styled("ol", "mt-4 list-decimal space-y-1 ps-6 text-start first:mt-0"),
  blockquote: styled("blockquote", "mt-4 border-s-4 border-slate-300 ps-4 italic text-slate-600 first:mt-0"),
  pre: styled("pre", "mt-4 overflow-x-auto rounded-xl bg-slate-900 p-4 text-left text-sm text-slate-100 first:mt-0 [&_code]:bg-transparent [&_code]:p-0"),
  th: styled("th", "border-b border-slate-300 px-3 py-2 font-semibold"),
  td: styled("td", "border-b border-slate-200 px-3 py-2"),
  a: ({ href, children }) => <a href={href} {...external} className="font-medium underline underline-offset-2">{children}</a>,
  code: ({ className, children }) => <code className={`rounded bg-slate-100 px-1 py-0.5 font-mono text-[0.9em] ${className ?? ""}`}>{children}</code>,
  hr: () => <hr className="my-8 border-slate-200" />,
  table: ({ children }) => <div className="mt-4 overflow-x-auto first:mt-0"><table className="w-full border-collapse text-left text-sm">{children}</table></div>,
  // eslint-disable-next-line @next/next/no-img-element -- arbitrary https hosts chosen by the author
  img: ({ src, alt }) => <img src={typeof src === "string" ? src : undefined} alt={alt ?? ""} loading="lazy" className="mt-4 inline-block max-w-full rounded-xl" />,
};

function Caption({ text }: { text: string | null | undefined }) {
  return text ? <figcaption className="mt-2 text-sm text-slate-500">{text}</figcaption> : null;
}

function MediaColumn({ type, column }: { type: Exclude<RichBlock["type"], "text">; column: RichColumn }) {
  const url = column.url ?? undefined;
  const media: ComponentProps<"video"> = { src: url, controls: true, preload: "metadata", className: "w-full rounded-xl bg-black" };
  return (
    <figure className="w-full">
      {type === "image" ? (
        // eslint-disable-next-line @next/next/no-img-element -- arbitrary https hosts chosen by the author
        <img src={url} alt={column.alt ?? column.caption ?? ""} loading="lazy" className="inline-block max-w-full rounded-xl" />
      ) : type === "video" ? (
        <video {...media} poster={column.posterUrl ?? undefined} playsInline />
      ) : (
        <audio src={url} controls preload="metadata" className="w-full" />
      )}
      <Caption text={column.caption} />
    </figure>
  );
}

function Block({ block }: { block: RichBlock }) {
  const align = ALIGN[block.align];
  return (
    <section id={`block-${block.id}`} className={`mt-8 first:mt-0 ${align.text}`}>
      <div className={`grid gap-6 ${block.columns.length > 1 ? "sm:grid-cols-2" : ""}`}>
        {block.columns.map((column, index) => (
          <div key={index} className={`flex min-w-0 flex-col ${align.items}`}>
            {block.type === "text"
              ? <div className="w-full"><Markdown remarkPlugins={[remarkGfm]} components={markdownComponents}>{column.markdown ?? ""}</Markdown></div>
              : <MediaColumn type={block.type} column={column} />}
          </div>
        ))}
      </div>
      {block.children.length ? (
        <ul className={`mt-4 flex flex-wrap gap-2 ${align.justify}`} aria-label="Links">
          {block.children.map((child, index) => (
            <li key={index}>
              <a href={child.url} {...external} className="md-chip inline-flex items-center gap-1 hover:underline">
                {child.title}
                <span aria-hidden>↗</span>
              </a>
            </li>
          ))}
        </ul>
      ) : null}
    </section>
  );
}

export function RichDocumentView({ document }: { document: RichDocument }) {
  return (
    <div className="mt-10 border-t border-slate-200 pt-10">
      {document.blocks.map((block) => <Block key={block.id} block={block} />)}
    </div>
  );
}
