/**
 * Local development helper: migrates TURSO_DATABASE_URL and inserts one sample summary using the
 * mock AI provider (no credentials needed). Prints the share path.
 *
 *   TURSO_DATABASE_URL=file:local.db bun scripts/seed-dev.ts
 *
 * Set OG_OUT=/path/to/file.png to also write the rendered OG image for a visual check.
 */
import { writeFileSync } from "node:fs";
import { MockAiProvider } from "../lib/ai/mock";
import { createDatabase } from "../lib/db/client";
import { ensureUser } from "../lib/services/users";
import { createSummary } from "../lib/services/summaries";
import { MemoryObjectStore } from "../lib/storage/r2";

const url = process.env.TURSO_DATABASE_URL;
if (!url || process.env.NODE_ENV === "production") {
  console.error("Set TURSO_DATABASE_URL (and do not run this in production)");
  process.exit(1);
}
const handle = createDatabase(url, process.env.TURSO_AUTH_TOKEN);
await handle.migrate(new URL("../drizzle", import.meta.url).pathname);
const principal = { sub: "dev-user", clientId: "dev", scopes: [] };
await ensureUser(handle.db, principal);
const store = new MemoryObjectStore();
const summary = await createSummary(handle.db, principal, {
  source: {
    type: "text",
    title: "How honeybees talk",
    text: "Honeybees communicate the location of flowers through a waggle dance. The angle of the dance relative to vertical encodes the direction of the food source relative to the sun, and the duration of the waggle run encodes distance.",
  },
  language: "auto",
  imageStyle: "graphic",
  visibility: "public",
}, { ai: new MockAiProvider(), store });
if (process.env.OG_OUT) {
  const [key] = [...store.objects.keys()];
  if (key) writeFileSync(process.env.OG_OUT, store.objects.get(key)!.bytes);
}
handle.close();
console.log(`/s/${summary.slug}`);
