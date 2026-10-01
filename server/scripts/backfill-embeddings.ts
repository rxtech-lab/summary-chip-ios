/**
 * Embeds every summary that has no search embedding yet (or one from an older `AI_EMBEDDING_MODEL`).
 * The daily cleanup cron does the same in bounded batches; run this once after enabling semantic search.
 * Run from the server directory: `bun run db:backfill-embeddings` (bun loads `.env` automatically).
 */
import { getAiProvider } from "../lib/ai/provider";
import { createDatabase } from "../lib/db/client";
import { backfillEmbeddings } from "../lib/services/embeddings";

const url = process.env.TURSO_DATABASE_URL;
if (!url) {
  console.error("TURSO_DATABASE_URL is required");
  process.exit(1);
}
const handle = createDatabase(url, process.env.TURSO_AUTH_TOKEN);
const report = await backfillEmbeddings(handle.db, await getAiProvider(), { maxBatches: 1_000 });
handle.close();
console.log(`Embedded ${report.embedded} summaries (${report.failed} failed)`);
