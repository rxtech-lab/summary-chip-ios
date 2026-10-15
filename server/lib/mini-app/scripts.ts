import { boundedMiniJson } from "./bounds";
import { Worker } from "node:worker_threads";
import path from "node:path";
import { jsonValue, type Json } from "@/lib/contracts/mini-app";
import { ApiError } from "@/lib/http/errors";
export async function runMiniScript(source: string, input: Json = null, check = false): Promise<Json> {
  if (!boundedMiniJson(input) || source.length > 50_000 || Buffer.byteLength(JSON.stringify(input)) > 1024 * 1024) throw new ApiError(422, "MINI_SCRIPT_LIMIT", "Script input is too large");
  return new Promise((resolve, reject) => {
    const worker = new Worker(path.join(process.cwd(), "lib/mini-app/script-worker.mjs"), { execArgv: [], env: {}, workerData: { source, input, check }, resourceLimits: { maxOldGenerationSizeMb: 64, stackSizeMb: 2 } });
    let finished = false;
    const finish = (error?: Error, value: Json = null) => {
      if (finished) return;
      finished = true; clearTimeout(timer); void worker.terminate();
      if (error) reject(error); else resolve(value);
    };
    const timer = setTimeout(() => finish(new ApiError(422, "MINI_SCRIPT_TIMEOUT", "Script exceeded its time budget")), 5000);
    worker.once("message", (result: { error?: string; value?: Json }) => {
      if (result.error) finish(new ApiError(422, "MINI_SCRIPT_ERROR", result.error));
      else if (!boundedMiniJson(result.value)) finish(new ApiError(422, "MINI_SCRIPT_ERROR", "Script JSON is too deeply nested"));
      else { const parsed = jsonValue.safeParse(result.value); finish(parsed.success ? undefined : new ApiError(422, "MINI_SCRIPT_ERROR", "Script must return JSON"), parsed.success ? parsed.data : null); }
    });
    worker.once("error", () => finish(new ApiError(503, "MINI_SCRIPT_UNAVAILABLE", "Script worker could not start")));
    worker.once("exit", () => finish(new ApiError(422, "MINI_SCRIPT_STOPPED", "Script worker stopped")));
  });
}
