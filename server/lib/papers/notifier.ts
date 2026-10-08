/** Keeps the Workflow runtime out of services and local tests. */
export interface PaperNotifier {
  start(paperId: string): Promise<void>;
}

let override: PaperNotifier | undefined;
export function setPaperNotifierForTests(notifier?: PaperNotifier): void { override = notifier; }

export function getPaperNotifier(): PaperNotifier {
  return override ?? {
    async start(paperId) {
      const [{ start }, { notifyPaperChanges }] = await Promise.all([import("workflow/api"), import("@/workflows/notify-paper-changes")]);
      await start(notifyPaperChanges, [paperId, crypto.randomUUID()]);
    },
  };
}
