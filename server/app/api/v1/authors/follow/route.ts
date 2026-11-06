import { and, eq, isNull } from "drizzle-orm";
import { z } from "zod";
import { authorFollows, users } from "@/lib/db/schema";
import { withApiAuth } from "@/lib/http/handler";
import { ApiError, noStoreJson, readJson } from "@/lib/http/errors";
export async function GET(request: Request) {
  return withApiAuth(request, async ({ db, principal }) => noStoreJson({ items: await db.select({ authorId: authorFollows.authorId }).from(authorFollows).where(eq(authorFollows.followerId, principal.sub)) }));
}
async function change(request: Request, follow: boolean) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { authorId } = await readJson(request, body => z.object({ authorId: z.string().min(1).max(200) }).parse(body));
    if (authorId === principal.sub) throw new ApiError(400, "INVALID_AUTHOR", "You cannot follow yourself");
    const [author] = await db.select({ id: users.id }).from(users).where(and(eq(users.id, authorId), isNull(users.deletionScheduledAt)));
    if (!author) throw new ApiError(404, "NOT_FOUND", "Author not found");
    if (follow) await db.insert(authorFollows).values({ followerId: principal.sub, authorId }).onConflictDoNothing();
    else await db.delete(authorFollows).where(and(eq(authorFollows.followerId, principal.sub), eq(authorFollows.authorId, authorId)));
    return noStoreJson({ following: follow });
  });
}
export const POST = (request: Request) => change(request, true);
export const DELETE = (request: Request) => change(request, false);
