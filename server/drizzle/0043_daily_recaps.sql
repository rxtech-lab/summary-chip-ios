CREATE TABLE `daily_recap_runs` (
	`id` text PRIMARY KEY NOT NULL,
	`owner_id` text NOT NULL,
	`date` text NOT NULL,
	`status` text NOT NULL,
	`episode_key` text,
	`error` text,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	FOREIGN KEY (`owner_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `daily_recap_owner_date_idx` ON `daily_recap_runs` (`owner_id`,`date`);--> statement-breakpoint
CREATE TABLE `daily_recap_schedules` (
	`owner_id` text PRIMARY KEY NOT NULL,
	`enabled` integer DEFAULT false NOT NULL,
	`time_zone` text NOT NULL,
	`language` text NOT NULL,
	`hour` integer DEFAULT 7 NOT NULL,
	`billing_environment` text,
	`next_at` integer NOT NULL,
	FOREIGN KEY (`owner_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `daily_recap_due_idx` ON `daily_recap_schedules` (`enabled`,`next_at`);