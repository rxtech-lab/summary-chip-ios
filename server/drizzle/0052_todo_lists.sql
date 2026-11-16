CREATE TABLE `todo_lists` (
	`summary_id` text PRIMARY KEY NOT NULL,
	`document` text NOT NULL,
	`revision` integer DEFAULT 0 NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`summary_id`) REFERENCES `summaries`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `todo_notification_deliveries` (
	`event_id` text NOT NULL,
	`installation_id` text NOT NULL,
	`owner_id` text NOT NULL,
	PRIMARY KEY(`event_id`, `installation_id`, `owner_id`),
	FOREIGN KEY (`event_id`) REFERENCES `todo_notifications`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `todo_notifications` (
	`id` text PRIMARY KEY NOT NULL,
	`summary_id` text NOT NULL,
	`item_id` text,
	`kind` text NOT NULL,
	`due_at` integer NOT NULL,
	`delivered` integer DEFAULT false NOT NULL,
	`runner_id` text,
	`lease_until` integer,
	FOREIGN KEY (`summary_id`) REFERENCES `summaries`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `todo_notifications_due_idx` ON `todo_notifications` (`delivered`,`due_at`);