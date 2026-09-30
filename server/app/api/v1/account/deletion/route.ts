import { cancelIdpDeletion, scheduleIdpDeletion } from "@/lib/auth/idp-account-deletion";
import { ApiError, noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import {
  cancelAccountDeletion,
  getPendingDeletion,
  scheduleAccountDeletion,
  type PendingDeletion,
} from "@/lib/services/account-deletion";

/**
 * Read, schedule and cancel the signed-in user's account deletion.
 *
 * rxlab-auth deletes the account; this server deletes the summaries. The session stays valid for
 * the whole grace period so the user can change their mind from the app.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function serialize(pending: PendingDeletion | null) {
  return {
    pendingDeletion: pending !== null,
    deletionScheduledAt: pending?.scheduledAt.toISOString() ?? null,
    deletionRequestedAt: pending?.requestedAt.toISOString() ?? null,
  };
}

export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    return noStoreJson(serialize(await getPendingDeletion(db, principal.sub)));
  });
}

/**
 * Identity provider first, then locally, adopting the IdP's deadline so both name the same
 * instant. Both sides are idempotent, so a retry after a failed local write converges.
 */
export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const remote = await scheduleIdpDeletion(request);
    const pending = await scheduleAccountDeletion(db, principal.sub, { scheduledAt: remote.scheduledAt ?? undefined });
    return noStoreJson(serialize(pending));
  });
}

/**
 * Locally first, then the identity provider. The reverse order could leave the account alive at
 * the IdP while our sweep still purges its summaries.
 */
export async function DELETE(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const pending = await getPendingDeletion(db, principal.sub);
    if (pending && !(await cancelAccountDeletion(db, principal.sub))) {
      throw new ApiError(409, "ACCOUNT_DELETION_IN_PROGRESS", "This account is already being deleted");
    }
    await cancelIdpDeletion(request);
    return noStoreJson(serialize(null));
  });
}
