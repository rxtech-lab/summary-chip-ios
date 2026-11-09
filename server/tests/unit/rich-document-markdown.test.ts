import { describe, expect, it } from "vitest";
import { richDocumentSchema } from "@/lib/contracts/rich-document";
import { blockIdAllocator, documentToMarkdown, markdownToBlocks, mediaTypeFor, plainText } from "@/lib/rich-document/markdown";

const SOURCE = `# Field notes

Intro paragraph with a [link](https://example.com).

## Footage

![Harbour at dawn](https://cdn.example.com/harbour.mp4 "Shot at 6am")
[Full gallery](https://example.com/gallery)

![Left](https://cdn.example.com/a.jpg)
![Right](https://cdn.example.com/b.jpg)

::: columns center
Left text
+++
**Right** text
:::

\`\`\`md
![not media](https://cdn.example.com/inside-code.jpg)
\`\`\`

![Interview](https://cdn.example.com/talk.m4a)
`;

describe("markdownToBlocks", () => {
  const { title, blocks } = markdownToBlocks(SOURCE, { takeTitle: true });

  it("takes the first heading as the title and splits sections into blocks", () => {
    expect(title).toBe("Field notes");
    expect(blocks.map((block) => block.type)).toEqual(["text", "text", "video", "image", "text", "text", "audio"]);
    expect(blocks[0].columns[0].markdown).toBe("Intro paragraph with a [link](https://example.com).");
    expect(blocks[1].columns[0].markdown).toBe("## Footage");
  });

  it("reads media lines, captions and link children", () => {
    expect(blocks[2]).toMatchObject({
      type: "video",
      columns: [{ url: "https://cdn.example.com/harbour.mp4", alt: "Harbour at dawn", caption: "Shot at 6am" }],
      children: [{ type: "link", title: "Full gallery", url: "https://example.com/gallery" }],
    });
  });

  it("pairs adjacent media into two columns and reads containers", () => {
    expect(blocks[3].columns.map((column) => column.url)).toEqual(["https://cdn.example.com/a.jpg", "https://cdn.example.com/b.jpg"]);
    expect(blocks[4]).toMatchObject({ type: "text", align: "center", columns: [{ markdown: "Left text" }, { markdown: "**Right** text" }] });
  });

  it("leaves code blocks alone", () => {
    expect(blocks[5].columns[0].markdown).toContain("inside-code.jpg");
  });

  it("produces a valid document with unique ids", () => {
    expect(richDocumentSchema.safeParse({ title: "x", blocks }).success).toBe(true);
    expect(new Set(blocks.map((block) => block.id)).size).toBe(blocks.length);
  });

  it("keeps non-https images as inline text", () => {
    const parsed = markdownToBlocks("![x](http://example.com/a.jpg)");
    expect(parsed.blocks).toMatchObject([{ type: "text" }]);
  });

  it("allocates ids around existing ones", () => {
    const next = blockIdAllocator(["b1", "b3"]);
    expect([next(), next(), next()]).toEqual(["b2", "b4", "b5"]);
  });
});

describe("documentToMarkdown", () => {
  it("round-trips blocks through Markdown", () => {
    const { title, blocks } = markdownToBlocks(SOURCE, { takeTitle: true });
    const markdown = documentToMarkdown({ version: 1, title: title!, blocks });
    const again = markdownToBlocks(markdown, { takeTitle: true });
    expect(again.title).toBe(title);
    expect(again.blocks).toEqual(blocks);
  });
});

describe("helpers", () => {
  it("types media by extension", () => {
    expect(mediaTypeFor("https://x.com/a.MP4?sig=1")).toBe("video");
    expect(mediaTypeFor("https://x.com/a.mp3")).toBe("audio");
    expect(mediaTypeFor("https://x.com/a")).toBe("image");
  });

  it("reduces Markdown to text", () => {
    expect(plainText("## Hello **world**\n\n- [a link](https://x.com)")).toBe("Hello world\n\na link");
  });
});
