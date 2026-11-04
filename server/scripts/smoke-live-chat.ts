/** Opt-in provider check. --audio requests a brief reply; never records a microphone. */
import { readFile } from "node:fs/promises";
import { type ToolSet } from "ai";
import { liveToolDefinitions } from "../lib/ai/live-tools";
import { createLiveChatSession, liveChatConfig } from "../lib/ai/live-chat";
const inputIndex = process.argv.indexOf("--input-pcm");
const inputAudio = inputIndex >= 0 ? await readFile(process.argv[inputIndex + 1]) : undefined;
if (inputAudio && (!inputAudio.length || inputAudio.length % 2)) throw new Error("Expected nonempty 16 kHz mono PCM16 audio");
let config = liveChatConfig;
if (process.argv.includes("--graph-tools")) {
  const { prepareChat } = await import("../lib/ai/chat");
  const { graphChatTools } = await import("../lib/ai/graph-agent");
  const { getDatabase } = await import("../lib/db/client");
  const db = getDatabase();
  const prepared = await prepareChat(db, "voice-smoke-check");
  const catalog: ToolSet = { ...prepared.tools, ...graphChatTools(db, "voice-smoke-check", "voice-smoke-graph", prepared.ai) };
  const tools = await liveToolDefinitions(catalog);
  config = { ...config, instructions: "Say hello. Do not call tools during this connection check.", tools };
}
const session = await createLiveChatSession(config);
const checkAudio = process.argv.includes("--audio") || !!inputAudio;
await new Promise<void>((resolve, reject) => {
  const socket = new WebSocket(session.url, session.protocols);
  let ready = false;
  let finished = false;
  let receivedAudio = false;
  const finish = (error?: Error) => {
    if (finished) return;
    finished = true;
    clearTimeout(timeout);
    socket.close();
    if (error) reject(error); else resolve();
  };
  const timeout = setTimeout(() => finish(new Error("Live setup/audio timed out")), 30000);
  socket.onopen = () => socket.send(JSON.stringify({ type: "session-update", config: session.config }));
  socket.onmessage = (message) => {
    const raw = JSON.parse(String(message.data));
    for (const event of Array.isArray(raw) ? raw : [raw]) {
      console.log("Live event:", event.type);
      if (["session-created", "session-updated", "session-started"].includes(event.type) && !ready) {
        ready = true;
        if (!checkAudio) { finish(); return; }
        if (inputAudio) {
          void (async () => {
            const samples = Buffer.concat([inputAudio, Buffer.alloc(16000 * 2 * 3)]);
            for (let offset = 0; offset < samples.length && !finished; offset += 3200) {
              socket.send(JSON.stringify({ type: "input-audio-append", audio: samples.subarray(offset, offset + 3200).toString("base64") }));
              await new Promise(resolve => setTimeout(resolve, 100));
            }
          })().catch(error => finish(error));
          continue;
        }
        socket.send(JSON.stringify({ type: "conversation-item-create", item: { type: "text-message", role: "user", text: "Say hello in one short sentence." } }));
      }
      if (["audio-delta", "audio-chunk"].includes(event.type) && typeof event.delta === "string") {
        receivedAudio ||= Buffer.from(event.delta, "base64").length > 0;
      }
      if (event.type === "response-done" && receivedAudio) finish();
      if (event.type === "error") finish(new Error("Provider rejected live session setup"));
    }
  };
  socket.onerror = () => finish(new Error("Live WebSocket failed"));
  socket.onclose = (event) => { if (!finished) finish(new Error(`Live socket closed: ${event.code} ${event.reason}`)); };
});
console.log(checkAudio ? "Live audio response verified:" : "Live Gateway setup acknowledged:", session.model);
