import { sandboxCredentials } from "../lib/podcast-video/sandbox-auth";
/** Run once per renderer update: bun scripts/prepare-podcast-renderer.ts.
 * Auth: Vercel OIDC locally via `vercel env pull`, or VERCEL_TOKEN/TEAM_ID/PROJECT_ID.
 * This creates a clean reusable snapshot, never a snapshot containing episode data.
 */
import { Sandbox } from "@vercel/sandbox";
const sandbox = await Sandbox.create({ ...sandboxCredentials(), timeout: 15 * 60_000, persistent: false,
  ...(process.env.PODCAST_RENDER_IMAGE ? { image: process.env.PODCAST_RENDER_IMAGE } : {}) });
let snapshotted = false;
try {
  // Managed images can start in /home/ubuntu without the renderer's workspace.
  const workspace = await sandbox.runCommand({ cmd: "sh", args: ["-c",
    'sudo install -d -o "$(id -u)" -g "$(id -g)" /vercel/sandbox'], cwd: "/" });
  if (workspace.exitCode !== 0) throw new Error("Could not create renderer workspace");
  const checked = async (cmd: string, args: string[]) => {
    console.log(`Renderer setup: ${cmd} ${args.join(" ")}`);
    const command = await sandbox.runCommand({ cmd, args, cwd: "/vercel/sandbox" });
    if (command.exitCode !== 0) throw new Error(`Renderer setup failed: ${cmd}: ${await command.stderr()}`);
  };
  // Universal sandbox image is Ubuntu-based. A supplied container image can bake these in.
  if (!process.env.PODCAST_RENDER_IMAGE) {
    await checked("sudo", ["apt-get", "update"]);
    await checked("sudo", ["apt-get", "install", "-y", "ffmpeg", "curl", "libnss3", "libatk-bridge2.0-0", "libdrm2",
      "libxkbcommon0", "libxcomposite1", "libxdamage1", "libxfixes3", "libxrandr2", "libgbm1", "libasound2t64", "fonts-noto-cjk", "fonts-noto-color-emoji"]);
  }
  await sandbox.writeFiles([{ path: "/vercel/sandbox/package.json", content: Buffer.from(JSON.stringify({ private: true, type: "module",
    dependencies: { remotion: "4.0.534", "@remotion/bundler": "4.0.534", "@remotion/renderer": "4.0.534", react: "19.2.8", "react-dom": "19.2.8" } })) }]);
  await checked("npm", ["install", "--no-audit", "--no-fund"]);
  await checked("node", ["--input-type=module", "-e", "import {ensureBrowser} from '@remotion/renderer'; await ensureBrowser();"]);
  await checked("ffmpeg", ["-version"]);
  await checked("ffprobe", ["-version"]);
  // Warm Chromium before freezing the image, and check that it can launch with these libraries.
  await checked("node", ["--input-type=module", "-e", "import {openBrowser} from '@remotion/renderer'; const b = await openBrowser('chrome'); await b.close({silent: true});"]);
  const snapshot = await sandbox.snapshot({ expiration: 0 });
  snapshotted = true; // snapshot() automatically stops the sandbox.
  console.log(`PODCAST_RENDER_SNAPSHOT_ID=${snapshot.snapshotId}`);
} finally {
  if (!snapshotted) await sandbox.stop();
}
