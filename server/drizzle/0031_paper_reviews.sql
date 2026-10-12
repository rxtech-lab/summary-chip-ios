CREATE TABLE `paper_reviews` (
	`id` text PRIMARY KEY NOT NULL,
	`summary_id` text NOT NULL,
	`owner_id` text NOT NULL,
	`file` text,
	`quote` text NOT NULL,
	`comment` text NOT NULL,
	`status` text DEFAULT 'open' NOT NULL,
	`version` integer NOT NULL,
	`addressed_version` integer,
	`agent_note` text,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`addressed_at` integer,
	`resolved_at` integer,
	FOREIGN KEY (`summary_id`) REFERENCES `papers`(`summary_id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`owner_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `paper_reviews_paper_idx` ON `paper_reviews` (`summary_id`,`created_at`);
