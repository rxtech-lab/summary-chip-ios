import { parentPort, workerData } from "node:worker_threads";
import { newQuickJSWASMModule, newVariant, RELEASE_SYNC } from "quickjs-emscripten";
// Runs an untrusted podcast composition for a few frames inside QuickJS: no Node APIs, network or
// timers are reachable, and the WASM heap and time budget are bounded. Returns plain element trees.
try {
  const wasmMemory = new WebAssembly.Memory({ initial: 256, maximum: 2048 });
  const quickJS = await newQuickJSWASMModule(newVariant(RELEASE_SYNC, { wasmMemory }));
  const runtime = quickJS.newRuntime();
  runtime.setMemoryLimit(96 * 1024 * 1024);
  runtime.setMaxStackSize(1024 * 1024);
  const deadline = Date.now() + workerData.budgetMs;
  runtime.setInterruptHandler(() => Date.now() > deadline);
  const context = runtime.newContext();
  try {
    const source = `${workerData.bundle}\nJSON.stringify(__preview.render(${JSON.stringify(workerData.frames)}, ${JSON.stringify(workerData.settings)}))`;
    const result = context.evalCode(source, "composition.js");
    if (result.error) {
      const error = context.dump(result.error);
      result.error.dispose();
      parentPort.postMessage({ error: String(error?.message ?? error ?? "Composition failed").slice(0, 400) });
    } else {
      const value = context.getString(result.value);
      result.value.dispose();
      if (value.length > 24 * 1024 * 1024) throw new Error("Frame output is too large");
      parentPort.postMessage({ value });
    }
  } finally { context.dispose(); runtime.dispose(); }
} catch (error) {
  parentPort.postMessage({ error: String(error?.message ?? "Frame preview failed").slice(0, 400) });
}
