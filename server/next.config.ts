import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  poweredByHeader: false,
  // Do not write AGENTS.md / CLAUDE.md into the package on `next dev`.
  agentRules: false,
  outputFileTracingIncludes: { "/api/v1/*": ["./lib/subscription/certificates/*.cer"] },
  /**
   * `@libsql/client` loads a native binding for local `file:` databases and pdf.js (via unpdf)
   * ships its own worker bundle, so both are required at runtime instead of being bundled.
   */
  serverExternalPackages: ["@libsql/client", "libsql", "unpdf", "linkedom", "sharp"],
};

export default nextConfig;
