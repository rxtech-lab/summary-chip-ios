import { sql } from "drizzle-orm";
import type { Database } from "@/lib/db/client";

type Transaction = Parameters<Parameters<Database["transaction"]>[0]>[0];
/** Keep staged assets and unbound previews for a day so an open editor can finish its export. */
export async function collectUnusedResumeOutputs(tx: Transaction, familyId: string | null, now = new Date()) {
  const cutoff = now.getTime() - 86_400_000;
  const scope = familyId ? sql`family_id=${familyId}` : sql`1`;
  await tx.run(sql`delete from resume_render_leases where ${scope} and expires_at<=${now.getTime()}`);
  await tx.run(sql`delete from resume_previews where ${scope} and created_at<${cutoff}
    and not exists (select 1 from resume_publications where preview_id=resume_previews.id)`);
  // UUIDs also appear in opaque override and translation snapshots. Exact quoted matches retain
  // those references regardless of the nesting used by a given contract version.
  await tx.run(sql`delete from resume_assets where ${scope} and created_at<${cutoff}
    and not exists (select 1 from resume_previews where asset_id=resume_assets.id)
    and not exists (select 1 from resume_render_leases where asset_id=resume_assets.id)
    and not exists (select 1 from resume_revisions where family_id=resume_assets.family_id
      and instr(payload,json_quote(resume_assets.id))>0)
    and not exists (select 1 from resume_receipts where family_id=resume_assets.family_id
      and instr(result,json_quote(resume_assets.id))>0)`);
}
