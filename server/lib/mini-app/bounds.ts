/** Iterative guard before recursive JSON/schema decoding or crossing a worker boundary. */
export function boundedMiniJson(input: unknown): boolean {
  const pending = [{ value: input, depth: 0 }]; let count = 0;
  while (pending.length) {
    const next = pending.pop()!;
    if (++count > 100_000 || next.depth > 40) return false;
    if (next.value && typeof next.value === "object") for (const value of Object.values(next.value)) pending.push({ value, depth: next.depth + 1 });
  }
  return true;
}
