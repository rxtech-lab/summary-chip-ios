/**
 * Applies `drizzle/` (including the hand-written FTS5 migration) to TURSO_DATABASE_URL.
 * Run from the server directory: `bun run db:migrate` (bun loads `.env` automatically).
 */
import { createDatabase } from "../lib/db/client";

const url = process.env.TURSO_DATABASE_URL;
if (!url) {
  console.error("TURSO_DATABASE_URL is required");
  process.exit(1);
}
const handle = createDatabase(url, process.env.TURSO_AUTH_TOKEN);
await handle.migrate(new URL("../drizzle", import.meta.url).pathname);
handle.close();
console.log("Migrations applied");
