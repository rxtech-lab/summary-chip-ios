CREATE TABLE `audiobook_jobs` (
	`id` text PRIMARY KEY NOT NULL,
	`owner_id` text NOT NULL,
	`document` text NOT NULL,
	`created_at` integer NOT NULL,
	`notified_at` integer,
	FOREIGN KEY (`owner_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `audiobook_jobs_owner_idx` ON `audiobook_jobs` (`owner_id`,`created_at`);
--> statement-breakpoint
CREATE TABLE `audiobook_plans` (
	`id` text PRIMARY KEY NOT NULL,
	`owner_id` text NOT NULL,
	`input` text NOT NULL,
	`plan` text NOT NULL,
	`revision` integer DEFAULT 0 NOT NULL,
	`confirmed` integer DEFAULT false NOT NULL,
	`frames` text DEFAULT '{}' NOT NULL,
	`messages` text DEFAULT '[]' NOT NULL,
	`passage_count` integer DEFAULT 0 NOT NULL,
	`source_characters` integer DEFAULT 0 NOT NULL,
	`source_seconds` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`owner_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `audiobook_plans_owner_idx` ON `audiobook_plans` (`owner_id`,`confirmed`,`updated_at`);
