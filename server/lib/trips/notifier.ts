/** Keeps the Workflow runtime out of services and local tests. */
export interface TripNotifier {
  start(batchId: string): Promise<void>;
}

let override: TripNotifier | undefined;
export function setTripNotifierForTests(notifier?: TripNotifier): void { override = notifier; }

export function getTripNotifier(): TripNotifier {
  return override ?? {
    async start(batchId) {
      const [{ start }, { notifyTripChanges }] = await Promise.all([import("workflow/api"), import("@/workflows/notify-trip-changes")]);
      await start(notifyTripChanges, [batchId, crypto.randomUUID()]);
    },
  };
}
