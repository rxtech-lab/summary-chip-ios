import { ZodError } from "zod";

/** An error that maps directly onto the contract's `{error:{code,message,requestId}}` JSON. */
export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
    public readonly details?: unknown,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

export function notFound(message = "The summary does not exist"): ApiError {
  return new ApiError(404, "NOT_FOUND", message);
}

export function errorResponse(error: unknown, requestId: string = crypto.randomUUID()): Response {
  const headers = { "cache-control": "no-store" };
  if (error instanceof ApiError) {
    return Response.json(
      {
        error: {
          code: error.code,
          message: error.message,
          requestId,
          ...(error.details === undefined ? {} : { details: error.details }),
        },
      },
      { status: error.status, headers },
    );
  }

  if (error instanceof ZodError) {
    return Response.json(
      {
        error: {
          code: "VALIDATION_ERROR",
          message: error.issues
            .slice(0, 3)
            .map((issue) => `${issue.path.join(".") || "body"}: ${issue.message}`)
            .join("; ") || "The request payload is invalid",
          requestId,
          details: error.issues.map((issue) => ({ path: issue.path, message: issue.message })),
        },
      },
      { status: 400, headers },
    );
  }

  console.error(`[api] unhandled error requestId=${requestId}`, error);
  return Response.json(
    { error: { code: "INTERNAL_ERROR", message: "An unexpected error occurred", requestId } },
    { status: 500, headers },
  );
}

const MAX_JSON_BYTES = 1_000_000;

/** Reads and validates a JSON body (≤ 1 MB). */
export async function readJson<T>(request: Request, parse: (value: unknown) => T): Promise<T> {
  const contentType = request.headers.get("content-type")?.split(";", 1)[0].trim().toLowerCase();
  if (contentType !== "application/json" && !contentType?.endsWith("+json")) {
    throw new ApiError(415, "UNSUPPORTED_MEDIA_TYPE", "Content-Type must be application/json");
  }
  const length = Number(request.headers.get("content-length") ?? 0);
  if (length > MAX_JSON_BYTES) throw new ApiError(413, "PAYLOAD_TOO_LARGE", "JSON payloads are limited to 1 MB");
  let body: unknown;
  try {
    const bytes = new Uint8Array(await request.arrayBuffer());
    if (bytes.byteLength > MAX_JSON_BYTES) {
      throw new ApiError(413, "PAYLOAD_TOO_LARGE", "JSON payloads are limited to 1 MB");
    }
    body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(400, "INVALID_JSON", "The request body must be valid JSON");
  }
  return parse(body);
}

export function noStoreJson(body: unknown, init?: ResponseInit): Response {
  const headers = new Headers(init?.headers);
  headers.set("cache-control", "private, no-store");
  return Response.json(body, { ...init, headers });
}
