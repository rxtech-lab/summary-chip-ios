/** Remuxes MPEG Layer III frames into one seekable MP3, without a native binary at runtime. */
interface Frame {
  bytes: Uint8Array;
  rate: number;
  samples: number;
  version: number;
  mono: boolean;
  side: number;
}
function header(bytes: Uint8Array, at: number): Frame {
  const version = (bytes[at + 1] >> 3) & 3;
  const bitrateIndex = bytes[at + 2] >> 4;
  const rateIndex = (bytes[at + 2] >> 2) & 3;
  if (bytes[at] !== 255 || (bytes[at + 1] & 224) !== 224 || version === 1 || ((bytes[at + 1] >> 1) & 3) !== 1 || !bitrateIndex || bitrateIndex === 15 || rateIndex === 3) {
    throw new Error("Expected MPEG Layer III audio");
  }
  const bitrate = (version === 3 ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160])[bitrateIndex] * 1000;
  const rate = [44100, 48000, 32000][rateIndex] / (version === 3 ? 1 : version === 2 ? 2 : 4);
  const length = Math.floor((version === 3 ? 144 : 72) * bitrate / rate) + ((bytes[at + 2] >> 1) & 1);
  if (at + length > bytes.length) throw new Error("Truncated MP3 frame");
  const mono = (bytes[at + 3] >> 6) === 3;
  return { bytes: bytes.slice(at, at + length), rate, samples: version === 3 ? 1152 : 576, version, mono,
    side: 4 + ((bytes[at + 1] & 1) ? 0 : 2) + (version === 3 ? mono ? 17 : 32 : mono ? 9 : 17) };
}
function frames(bytes: Uint8Array): Frame[] {
  let at = 0;
  const text = (start: number, count: number) => new TextDecoder().decode(bytes.subarray(start, start + count));
  if (text(0, 3) === "ID3") {
    if (bytes.length < 10) throw new Error("Truncated ID3 tag");
    at = 10 + ((bytes[6] & 127) * 2097152 + (bytes[7] & 127) * 16384 + (bytes[8] & 127) * 128 + (bytes[9] & 127));
    if (bytes[5] & 16) at += 10;
  }
  const result: Frame[] = [];
  while (at < bytes.length) {
    if (bytes.length - at === 128 && text(at, 3) === "TAG") break;
    const frame = header(bytes, at);
    const signature = text(at + frame.side, 4);
    if (!["Xing", "Info"].includes(signature) && text(at + 36, 4) !== "VBRI") result.push(frame);
    at += frame.bytes.length;
  }
  if (!result.length) throw new Error("MP3 has no audio frames");
  return result;
}

export function joinPodcastAudio(parts: Uint8Array[]) {
  const groups = parts.map(frames);
  const all = groups.flat();
  const first = all[0];
  if (!first || all.some((frame) => frame.rate !== first.rate || frame.version !== first.version || frame.mono !== first.mono)) {
    throw new Error("Podcast voices must use the same MP3 sample rate and channel layout");
  }
  // A fresh Xing frame describes the whole recording; retaining each turn's old seek header
  // would cause players to report only the first turn's duration or stop at its boundary.
  const prefix = Uint8Array.from(first.bytes.subarray(0, 4));
  prefix[1] |= 1; // no CRC on our metadata frame
  prefix[2] = (prefix[2] & 15) | 224; // largest legal bitrate, leaving room for the seek table
  const padded = new Uint8Array(4096);
  padded.set(prefix);
  const info = header(padded, 0);
  const bytes = new Uint8Array(info.bytes.length + all.reduce((sum, frame) => sum + frame.bytes.length, 0));
  bytes.set(prefix);
  bytes.set(new TextEncoder().encode("Xing"), info.side);
  const view = new DataView(bytes.buffer);
  view.setUint32(info.side + 4, 7); // frames, bytes, table of contents
  view.setUint32(info.side + 8, all.length);
  view.setUint32(info.side + 12, bytes.length);
  let offset = info.bytes.length;
  const offsets = all.map((frame) => { const start = offset; bytes.set(frame.bytes, offset); offset += frame.bytes.length; return start; });
  for (let percent = 0; percent < 100; percent++) {
    bytes[info.side + 16 + percent] = Math.min(255, Math.floor(256 * offsets[Math.floor(percent * all.length / 100)] / bytes.length));
  }
  let elapsed = 0;
  const cues = groups.map((group) => {
    const startSeconds = elapsed;
    elapsed += group.reduce((sum, frame) => sum + frame.samples / frame.rate, 0);
    return { startSeconds, endSeconds: elapsed };
  });
  return { bytes, cues, durationSeconds: elapsed };
}
