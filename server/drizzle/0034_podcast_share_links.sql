CREATE TABLE `podcast_share_links` (
	`id` text PRIMARY KEY NOT NULL,
	`owner_id` text NOT NULL,
	`episode_key` text NOT NULL,
	`day` text NOT NULL,
	`token` text NOT NULL,
	`label` text,
	`ttl_days` integer,
	`expires_at` integer,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	FOREIGN KEY (`owner_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `podcast_share_links_token_unique` ON `podcast_share_links` (`token`);--> statement-breakpoint
CREATE INDEX `podcast_share_links_episode_idx` ON `podcast_share_links` (`owner_id`,`episode_key`,`created_at`);--> statement-breakpoint
DROP TABLE `podcast_publications`;
