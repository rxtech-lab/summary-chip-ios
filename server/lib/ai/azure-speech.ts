/** Azure Speech over REST (`AZURE_SPEECH_KEY`, `AZURE_SPEECH_REGION`); one request returns a complete MP3. */
const ATTEMPTS = 4;
const OUTPUT_FORMAT = "audio-24khz-96kbitrate-mono-mp3";

function escapeXml(text: string) {
  return text.replace(/[<>&'"]/g, (character) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", "'": "&apos;", '"': "&quot;" })[character]!);
}

/** The SSML for one turn. Multilingual voices detect the text's language, so the locale only names the voice's own. */
export function azureSsml(voice: string, text: string) {
  const locale = /^[a-z]{2}-[A-Z]{2}/.exec(voice)?.[0] ?? "en-US";
  return `<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="${locale}"><voice name="${escapeXml(voice)}">${escapeXml(text)}</voice></speak>`;
}

export async function azureSpeak(text: string, voice: string, abortSignal?: AbortSignal): Promise<{ bytes: Uint8Array; mediaType: string }> {
  const key = process.env.AZURE_SPEECH_KEY?.trim();
  const region = process.env.AZURE_SPEECH_REGION?.trim();
  if (!key || !region) throw new Error("Azure Speech is not configured");
  let failure: unknown;
  for (let attempt = 0; attempt < ATTEMPTS; attempt++) {
    if (attempt) await new Promise((resolve) => setTimeout(resolve, 750 * 2 ** (attempt - 1)));
    abortSignal?.throwIfAborted();
    try {
      const timeout = AbortSignal.timeout(45_000);
      const response = await fetch(`https://${encodeURIComponent(region)}.tts.speech.microsoft.com/cognitiveservices/v1`, {
        method: "POST",
        headers: { "Ocp-Apim-Subscription-Key": key, "Content-Type": "application/ssml+xml", "X-Microsoft-OutputFormat": OUTPUT_FORMAT, "User-Agent": "chippy" },
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
