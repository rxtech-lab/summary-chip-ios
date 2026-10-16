import { parentPort, workerData } from "node:worker_threads";
import { newQuickJSWASMModule, newVariant, RELEASE_SYNC } from "quickjs-emscripten";
try {
  // The QuickJS build ignores setMemoryLimit, so bound the WASM heap itself: 16 MiB to start,
  // at most 48 MiB (32 MiB for the script). Running out fails the script with "out of memory".
  const wasmMemory = new WebAssembly.Memory({ initial: 256, maximum: 768 });
  const quickJS = await newQuickJSWASMModule(newVariant(RELEASE_SYNC, { wasmMemory }));
  const runtime = quickJS.newRuntime();
  runtime.setMemoryLimit(32 * 1024 * 1024);
  runtime.setMaxStackSize(256 * 1024);
  const deadline = Date.now() + 1000;
  runtime.setInterruptHandler(() => Date.now() > deadline);
  const context = runtime.newContext();
  try {
    const source = workerData.check
      ? `(function(input) { "use strict";\n${workerData.source}\n})`
      : `JSON.stringify((function(input) { "use strict";\n${workerData.source}\n})(${JSON.stringify(workerData.input)}))`;
    const result = context.evalCode(source, "mini-app.js");
    if (result.error) {
      const error = context.dump(result.error);
      result.error.dispose();
      parentPort.postMessage({ error: String(error?.message ?? "Script failed").slice(0, 300) });
    } else {
      const value = workerData.check ? "null" : context.getString(result.value);
      result.value.dispose();
      if (Buffer.byteLength(value) > 1024 * 1024) throw new Error("Script output exceeds 1 MiB");
      parentPort.postMessage({ value: JSON.parse(value) });
    }
  } finally { context.dispose(); runtime.dispose(); }
} catch { parentPort.postMessage({ error: "Script must return bounded JSON" }); }
