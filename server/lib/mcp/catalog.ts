import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import { createMcpServer, type McpContext } from "./server";

/** Read the actual MCP registrations through tools/list, without calling tools or using an API key. */
export async function listMcpTools(context: McpContext): Promise<Pick<Tool, "name" | "title" | "description">[]> {
  const server = createMcpServer(context);
  const client = new Client({ name: "chippy-settings", version: "1.0.0" });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  try {
    await server.connect(serverTransport);
    await client.connect(clientTransport);
    const items: Pick<Tool, "name" | "title" | "description">[] = [];
    let cursor: string | undefined;
    do {
      const page = await client.listTools(cursor ? { cursor } : undefined);
      items.push(...page.tools.map(({ name, title, description }) => ({ name, title, description })));
      cursor = page.nextCursor;
    } while (cursor);
    return items;
  } finally {
    await client.close();
    await server.close();
  }
}
