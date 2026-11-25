import { flowcyInference } from "./flowcy";

const ATTEMPTS = 4;

function escapeXml(text: string) {
  return text.replace(/[<>&'"]/g, (character) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", "'": "&apos;", '"': "&quot;" })[character]!);
}

/** The SSML for one turn. Multilingual voices detect the text's language, so the locale only names the voice's own. */
export function azureSsml(voice: string, text: string) {
  const locale = /^[a-z]{2}-[A-Z]{2}/.exec(voice)?.[0] ?? "en-US";
  return `<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="${locale}"><voice name="${escapeXml(voice)}">${escapeXml(text)}</voice></speak>`;
}

export async function azureSpeak(text: string, voice: string, abortSignal?: AbortSignal): Promise<{ bytes: Uint8Array; mediaType: string }> {
  let failure: unknown;
  for (let attempt = 0; attempt < ATTEMPTS; attempt++) {
    if (attempt) await new Promise((resolve) => setTimeout(resolve, 750 * 2 ** (attempt - 1)));
    abortSignal?.throwIfAborted();
    try {
      const timeout = AbortSignal.timeout(45_000);
      const response = await flowcyInference("azure-speech", {
        method: "POST",
        headers: { "Content-Type": "application/ssml+xml" },
        body: azureSsml(voice, text),
        signal: abortSignal ? AbortSignal.any([abortSignal, timeout]) : timeout,
      });
      if (response.ok) return { bytes: new Uint8Array(await response.arrayBuffer()), mediaType: "audio/mpeg" };
      const message = `Azure Speech ${response.status}: ${(await response.text().catch(() => "")).slice(0, 200)}`;
      // Only rate limits and server errors can pass on another try.
      if (response.status !== 429 && response.status < 500) throw Object.assign(new Error(message), { permanent: true });
      failure = new Error(message);
    } catch (error) {
      if ((error as { permanent?: boolean }).permanent || abortSignal?.aborted) throw error;
      failure = error;
    }
  }
  throw new Error(`Azure Speech failed after ${ATTEMPTS} attempts`, { cause: failure });
}
