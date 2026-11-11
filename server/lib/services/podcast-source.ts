import type { PodcastInput } from "@/lib/ai/podcast-agent";
import type { PodcastCreationInput } from "@/lib/contracts/daily-podcast";
import type { SummaryRow } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import type { ObjectStore } from "@/lib/storage/r2";
import { chipSourceText } from "./audiobook-source";

/** Bound the model context without silently discarding later sections of a document. */
export const MAX_PODCAST_SOURCE_CHARACTERS = 300_000;

export async function podcastSources(chips: SummaryRow[], viewer: string, input: Pick<PodcastCreationInput, "sourceMode">, store: ObjectStore): Promise<PodcastInput["chips"]> {
  let characters = 0;
  const sources: PodcastInput["chips"] = [];
  for (const chip of chips) {
    const source = { id: chip.id, title: chip.title, summary: chip.summary, highlights: chip.highlights };
    if (input.sourceMode !== "fullText") { sources.push(source); continue; }
    // Re-read owned PDFs when available; an excerpt alone cannot support a full-source episode.
    const sourceText = (await chipSourceText({ ...chip, contentExcerpt: "" }, viewer, store)).trim();
    if (!sourceText && chip.contentMarkdown === "") throw new ApiError(409, "PODCAST_SOURCE_PENDING", `The saved source text for “${chip.title}” is still being prepared. Wait for the source document to finish, then try again.`);
    if (!sourceText) throw new ApiError(422, "PODCAST_NO_SOURCE_TEXT", `“${chip.title}” has no saved source text available. Save its source document or upload the PDF again, or choose Chip Summaries.`);
    characters += sourceText.length;
    if (characters > MAX_PODCAST_SOURCE_CHARACTERS) throw new ApiError(422, "PODCAST_SOURCE_TOO_LONG", "The full sources exceed 300,000 characters. Choose fewer chips, upload a shorter PDF, or use an audiobook for a longer document.");
    sources.push({ ...source, sourceText });
  }
  return sources;
}
