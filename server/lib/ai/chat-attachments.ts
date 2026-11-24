import type { UIMessage } from "ai";
import { z } from "zod";
import { createFileUploadSchema, MAX_TEXT_LENGTH } from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { ApiError } from "@/lib/http/errors";
import { getCompletedUpload } from "@/lib/services/uploads";
import { getObjectStore } from "@/lib/storage/r2";

const MAX_FILE_BYTES = 25 * 1024 * 1024;
const MAX_FILES_PER_MESSAGE = 5;
const chatMimeType = z.enum(["text/plain", "application/pdf", "image/jpeg", "image/png", "image/webp"]);

export const chatUploadSchema = createFileUploadSchema.extend({
  mimeType: chatMimeType,
  byteSize: createFileUploadSchema.shape.byteSize.max(MAX_FILE_BYTES),
}).refine(input => input.mimeType !== "text/plain" || input.byteSize <= MAX_TEXT_LENGTH, {
  path: ["byteSize"], message: `Text attachments must be at most ${MAX_TEXT_LENGTH} UTF-8 bytes`,
});

export const chatAttachmentsSchema = z.array(z.object({
  uploadKey: z.string().min(1).max(300),
  filename: z.string().trim().min(1).max(300),
})).max(MAX_FILES_PER_MESSAGE);
export type ChatAttachments = z.infer<typeof chatAttachmentsSchema>;
export type ChatMessageWithAttachments = UIMessage<{ attachments: ChatAttachments }>;

async function attachmentPart(
  db: Database, ownerId: string, reference: ChatAttachments[number], historical: boolean,
  budget: { remainingBytes: number },
): Promise<UIMessage["parts"][number]> {
  const store = getObjectStore();
  try {
    const key = reference.uploadKey;
    const { upload, mimeType } = await getCompletedUpload(db, ownerId, key, store, MAX_FILE_BYTES, "chat-uploads");
    chatUploadSchema.parse({ filename: upload.filename, byteSize: upload.byteSize, mimeType });
    if (upload.byteSize > budget.remainingBytes) {
      return { type: "text", text: `Previously attached file ${JSON.stringify(upload.filename)} was omitted from this turn to limit attachment size.` };
    }
    const { bytes } = await store.get(key);
    budget.remainingBytes -= upload.byteSize;
    if (mimeType === "text/plain") {
      let text: string;
      try {
        text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
      } catch {
        throw new ApiError(422, "INVALID_TEXT_ATTACHMENT", `"${upload.filename}" must contain UTF-8 text`);
      }
      return { type: "text", text: `Attached file ${JSON.stringify(upload.filename)}:\n${text}` };
    }
    const url = `data:${mimeType};base64,${Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString("base64")}`;
    return { type: "file", filename: upload.filename, mediaType: mimeType, url };
  } catch (error) {
    // The previous turn may refer to an upload already removed by daily cleanup.
    if (historical && error instanceof ApiError && ["UPLOAD_NOT_FOUND", "UPLOAD_INCOMPLETE", "OBJECT_MISSING"].includes(error.code)) {
      return { type: "text", text: `Previously attached file ${JSON.stringify(reference.filename)} is no longer available.` };
    }
    throw error;
  }
}

/** Prioritize the latest turn and bound the total bytes materialized for the model. */
export async function resolveChatAttachments(
  db: Database, ownerId: string, messages: ChatMessageWithAttachments[],
): Promise<UIMessage[]> {
  const resolved: UIMessage[] = [...messages];
  const budget = { remainingBytes: MAX_FILE_BYTES * MAX_FILES_PER_MESSAGE };
  for (let index = messages.length - 1; index >= 0; index--) {
    const message = messages[index];
    const attachments = message.metadata?.attachments;
    if (!attachments?.length) continue;
    const parts = [...message.parts];
    for (const reference of attachments) {
      parts.push(await attachmentPart(db, ownerId, reference, index < messages.length - 1, budget));
    }
    resolved[index] = { id: message.id, role: message.role, parts };
  }
  return resolved;
}
