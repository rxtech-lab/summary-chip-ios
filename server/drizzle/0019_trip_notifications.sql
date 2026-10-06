CREATE TABLE `trip_notification_batches` (
  `id` text PRIMARY KEY NOT NULL,
  `trip_id` text NOT NULL REFERENCES `trips`(`summary_id`) ON DELETE CASCADE,
  `revision` integer NOT NULL,
  `before_document` text NOT NULL,
  `after_document` text NOT NULL,
  `due_at` integer NOT NULL,
  `status` text DEFAULT 'pending' NOT NULL,
  `change_summary` text,
  `runner_id` text,
  `lease_until` integer
);
--> statement-breakpoint
CREATE UNIQUE INDEX `trip_notifications_pending_unique` ON `trip_notification_batches` (`trip_id`) WHERE `status` = 'pending';
--> statement-breakpoint
CREATE INDEX `trip_notifications_due_idx` ON `trip_notification_batches` (`due_at`);
--> statement-breakpoint
CREATE TABLE `trip_notification_deliveries` (
  `batch_id` text NOT NULL REFERENCES `trip_notification_batches`(`id`) ON DELETE CASCADE,
  `installation_id` text NOT NULL,
  `user_id` text NOT NULL REFERENCES `users`(`id`) ON DELETE CASCADE,
  PRIMARY KEY (`batch_id`, `installation_id`, `user_id`)
);
