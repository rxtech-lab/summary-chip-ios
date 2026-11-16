import { createTodoSchema } from "@/lib/contracts/todo";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { createTodoList, listTodoLists } from "@/lib/services/todo-lists";
export const runtime = "nodejs";
export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => noStoreJson(await listTodoLists(db, principal.sub)));
}
export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, (body) => createTodoSchema.parse(body));
    return noStoreJson({ todoList: await createTodoList(db, principal, input) }, { status: 201 });
  });
}
