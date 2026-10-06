CREATE TABLE `share_links` (
	`id` text PRIMARY KEY NOT NULL,
	`summary_id` text NOT NULL,
	`token` text NOT NULL,
	`label` text,
	`access` text DEFAULT 'anyone' NOT NULL,
	`ttl_days` integer,
	`expires_at` integer,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	FOREIGN KEY (`summary_id`) REFERENCES `summaries`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `share_links_token_unique` ON `share_links` (`token`);--> statement-breakpoint
CREATE INDEX `share_links_summary_idx` ON `share_links` (`summary_id`,`created_at`);--> statement-breakpoint
CREATE TABLE `share_link_emails` (
	`link_id` text NOT NULL,
	`email` text NOT NULL,
	`added_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	PRIMARY KEY(`link_id`, `email`),
	FOREIGN KEY (`link_id`) REFERENCES `share_links`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
ALTER TABLE `summary_views` ADD `share_link_id` text REFERENCES share_links(id) ON DELETE set null;
