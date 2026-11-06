import Link from "next/link";
import { eq } from "drizzle-orm";
import { getDatabase } from "@/lib/db/client";
import { users } from "@/lib/db/schema";
export async function PublicAuthor({ ownerId }: { ownerId: string }) {
  const [author] = await getDatabase().select({ name: users.name }).from(users).where(eq(users.id, ownerId));
  return <Link href={`/discover?author=${encodeURIComponent(ownerId)}`} className="text-sm font-medium">By {author?.name || "Chippy author"} · View author’s content</Link>;
}
