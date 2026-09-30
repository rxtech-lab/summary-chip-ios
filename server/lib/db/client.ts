import { createClient, type Client } from "@libsql/client";
import { drizzle, type LibSQLDatabase } from "drizzle-orm/libsql";
import { migrate } from "drizzle-orm/libsql/migrator";
import path from "node:path";
import * as schema from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";

export type Database = LibSQLDatabase<typeof schema>;

export interface DatabaseHandle {
  db: Database;
  client: Client;
  /** Applies `drizzle/` migrations. Defaults to `<cwd>/drizzle`; scripts pass their own path. */
  migrate: (migrationsFolder?: string) => Promise<void>;
  close: () => void;
}

export const MIGRATIONS_FOLDER = path.join(process.cwd(), "drizzle");

export function createDatabase(url: string, authToken?: string): DatabaseHandle {
  const client = createClient({ url, authToken: authToken || undefined });
  const db = drizzle(client, { schema });
  return {
    db,
    client,
    migrate: (migrationsFolder = MIGRATIONS_FOLDER) => migrate(db, { migrationsFolder }),
    close: () => client.close(),
  };
}

let singleton: DatabaseHandle | undefined;
let testDatabase: Database | undefined;

/** Lazily opened so `next build` never needs database credentials. */
export function getDatabase(): Database {
  if (testDatabase) return testDatabase;
  if (!singleton) {
    const url = process.env.TURSO_DATABASE_URL;
    if (!url) throw new ApiError(503, "DATABASE_NOT_CONFIGURED", "TURSO_DATABASE_URL is not configured");
    singleton = createDatabase(url, process.env.TURSO_AUTH_TOKEN);
  }
  return singleton.db;
}

export function setDatabaseForTests(db?: Database): void {
  testDatabase = db;
}
