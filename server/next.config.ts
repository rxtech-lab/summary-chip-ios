import type { NextConfig } from "next";
import { withWorkflow } from "workflow/next";

const nextConfig: NextConfig = {
  poweredByHeader: false,
  // Do not write AGENTS.md / CLAUDE.md into the package on `next dev`.
  agentRules: false,
  outputFileTracingIncludes: {
    "/api/v1/mini-apps/**": ["./lib/mini-app/script-worker.mjs", "./node_modules/quickjs-emscripten/**", "./node_modules/quickjs-emscripten-core/**", "./node_modules/@jitl/**"],
    "/api/v1/chat": ["./lib/mini-app/script-worker.mjs", "./node_modules/quickjs-emscripten/**", "./node_modules/quickjs-emscripten-core/**", "./node_modules/@jitl/**"],
    "/api/v1/*": ["./lib/subscription/certificates/*.cer"],
    "/api/mcp": ["./lib/mini-app/script-worker.mjs", "./node_modules/quickjs-emscripten/**", "./node_modules/quickjs-emscripten-core/**", "./node_modules/@jitl/**", "./lib/subscription/certificates/*.cer"],
    "/api/v1/papers/*/export": ["./lib/latex/pandoc-worker.mjs", "./node_modules/pandoc-wasm/package.json", "./node_modules/pandoc-wasm/index.js", "./node_modules/pandoc-wasm/src/**", "./node_modules/@bjorn3/browser_wasi_shim/package.json", "./node_modules/@bjorn3/browser_wasi_shim/dist/*.js"],
  },
  /**
   * `@libsql/client` loads a native binding for local `file:` databases and pdf.js (via unpdf)
   * ships its own worker bundle, so both are required at runtime instead of being bundled.
   * esbuild (podcast video validation) spawns its platform binary.
   */
  serverExternalPackages: ["@libsql/client", "libsql", "unpdf", "linkedom", "sharp", "esbuild"],
};

// Compiles `"use workflow"` / `"use step"` (the flight tracker in `workflows/`).
export default withWorkflow(nextConfig);
