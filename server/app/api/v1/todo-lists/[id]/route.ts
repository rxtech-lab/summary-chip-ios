import { updateTodoSchema } from "@/lib/contracts/todo";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { getTodoList, updateTodoList } from "@/lib/services/todo-lists";
import { deleteSummary } from "@/lib/services/summaries";
export const runtime = "nodejs";
type Context = { params: Promise<{ id: string }> };
export async function GET(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => noStoreJson({ todoList: await getTodoList(db, (await params).id, principal.sub) }));
}
export async function PUT(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, (body) => updateTodoSchema.parse(body));
    return noStoreJson({ todoList: await updateTodoList(db, principal.sub, (await params).id, input) });
  });
}
export async function DELETE(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    await getTodoList(db, id, principal.sub, true);
    await deleteSummary(db, principal.sub, id);
    return new Response(null, { status: 204 });
  });
}
