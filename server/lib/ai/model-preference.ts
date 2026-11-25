import { AsyncLocalStorage } from "node:async_hooks";
import { eq } from "drizzle-orm";
import type { Database } from "@/lib/db/client";
import { users } from "@/lib/db/schema";

type Account = { db: Database; user: string; model?: Promise<string | null> };
const accounts = new AsyncLocalStorage<Account>();

export function withAIAccount<T>(db: Database, user: string, run: () => T): T {
  return accounts.run({ db, user }, run);
}

export async function readModelPreference(db: Database, user: string) {
  const [row] = await db.select({ id: users.aiModelId }).from(users).where(eq(users.id, user)).limit(1);
  return row?.id ?? null;
}

/** A request that does no inference does not need to read the preference. */
export function accountModelId(): Promise<string | null> {
  const account = accounts.getStore();
  if (!account) return Promise.resolve(null);
  return account.model ??= readModelPreference(account.db, account.user);
}
