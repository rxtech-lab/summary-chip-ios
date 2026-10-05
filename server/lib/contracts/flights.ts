import { z } from "zod";

/** Request bodies of the flight endpoints. Spec: `docs/flights.md`. */

const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "must be YYYY-MM-DD");
// ActivityKit tokens are opaque and variable in length; sent as hexadecimal by the app.
const hexToken = z.string().regex(/^(?:[a-fA-F0-9]{2}){16,256}$/).transform((value) => value.toLowerCase());

export const flightLookupSchema = z.object({
  flightNumber: z.string().trim().min(2).max(12),
  date: isoDate,
}).strict();
export type FlightLookupInput = z.infer<typeof flightLookupSchema>;

export const liveActivityStartTokenSchema = z.object({
  installationId: z.uuid(),
  pushToStartToken: hexToken.nullable(),
}).strict();

export const flightLiveActivitySchema = z.object({
  installationId: z.uuid(),
  token: hexToken,
  environment: z.enum(["sandbox", "production"]),
}).strict();

export const flightLiveActivityRemovalSchema = z.object({ installationId: z.uuid() }).strict();
