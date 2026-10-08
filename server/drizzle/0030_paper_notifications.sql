CREATE TABLE `paper_notification_batches` (
	`paper_id` text PRIMARY KEY NOT NULL,
	`created` integer DEFAULT false NOT NULL,
	`revision` integer NOT NULL,
	`due_at` integer NOT NULL,
	`runner_id` text,
	`lease_until` integer,
	FOREIGN KEY (`paper_id`) REFERENCES `papers`(`summary_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `paper_notifications_due_idx` ON `paper_notification_batches` (`due_at`);
