CREATE TABLE `trip_reminder_deliveries` (
	`trip_id` text NOT NULL,
	`event_key` text NOT NULL,
	`installation_id` text NOT NULL,
	`user_id` text NOT NULL,
	PRIMARY KEY(`trip_id`, `event_key`, `installation_id`, `user_id`),
	FOREIGN KEY (`trip_id`) REFERENCES `trips`(`summary_id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `trip_reminder_schedules` (
	`trip_id` text PRIMARY KEY NOT NULL,
	`runner_id` text NOT NULL,
	`next_at` integer,
	`lease_until` integer,
	FOREIGN KEY (`trip_id`) REFERENCES `trips`(`summary_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `trip_reminders_due_idx` ON `trip_reminder_schedules` (`next_at`);