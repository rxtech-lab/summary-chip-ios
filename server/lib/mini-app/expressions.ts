import { isDeepStrictEqual } from "node:util";
import type { Json } from "@/lib/contracts/mini-app";
import { ApiError } from "@/lib/http/errors";

const forbidden = new Set(["__proto__", "constructor", "prototype"]);
export function readPath(value: Json, path: string): Json {
  let current = value;
  for (const key of path.split(".")) {
    if (forbidden.has(key) || current === null || typeof current !== "object" || !Object.hasOwn(current, key)) return null;
    current = (current as Record<string, Json>)[key] ?? null;
  }
  return current;
}
export function writePath(state: Record<string, Json>, path: string, value: Json) {
  const keys = path.split(".");
  if (keys.some(k => !k || forbidden.has(k))) throw new ApiError(422, "MINI_EXPRESSION_INVALID", "Invalid state path");
  let target = state;
  for (const key of keys.slice(0, -1)) {
    const existing = target[key];
    if (!existing || typeof existing !== "object" || Array.isArray(existing)) target[key] = {};
    target = target[key] as Record<string, Json>;
  }
  target[keys.at(-1)!] = value;
}
export function evaluate(value: Json, context: Record<string, Json>, depth = 0): Json {
  if (depth > 24) throw new ApiError(422, "MINI_EXPRESSION_INVALID", "Expression is too deep");
  if (!value || typeof value !== "object") return value;
  if (Array.isArray(value)) return value.map(v => evaluate(v, context, depth + 1));
  if (typeof value.get === "string" && Object.keys(value).length === 1) return readPath(context, value.get);
  if (typeof value.op === "string" && Array.isArray(value.args)) {
    const a = value.args.map(v => evaluate(v, context, depth + 1));
    const num = (v: Json) => typeof v === "number" ? v : 0;
    switch (value.op) {
      case "eq": return isDeepStrictEqual(a[0], a[1]);
      case "ne": return !isDeepStrictEqual(a[0], a[1]);
      case "gt": return num(a[0]) > num(a[1]);
      case "gte": return num(a[0]) >= num(a[1]);
      case "lt": return num(a[0]) < num(a[1]);
      case "lte": return num(a[0]) <= num(a[1]);
      case "and": return a.every(Boolean);
      case "or": return a.some(Boolean);
      case "not": return !a[0];
      case "add": return a.reduce<number>((s, v) => s + num(v), 0);
      case "sub": return num(a[0]) - num(a[1]);
      case "mul": return a.reduce<number>((s, v) => s * num(v), 1);
      case "div": return num(a[1]) === 0 ? null : num(a[0]) / num(a[1]);
      case "concat": return a.map(v => v === null ? "" : String(v)).join("");
      case "length": return typeof a[0] === "string" || Array.isArray(a[0]) ? a[0].length : 0;
      case "coalesce": return a.find(v => v !== null) ?? null;
      case "contains": return typeof a[0] === "string" ? a[0].includes(String(a[1])) : Array.isArray(a[0]) && a[0].some(v => isDeepStrictEqual(v, a[1]));
      default: throw new ApiError(422, "MINI_EXPRESSION_INVALID", "Unsupported expression");
    }
  }
  return Object.fromEntries(Object.entries(value).map(([k, v]) => {
    if (forbidden.has(k)) throw new ApiError(422, "MINI_EXPRESSION_INVALID", "Invalid object key");
    return [k, evaluate(v, context, depth + 1)];
  }));
}
