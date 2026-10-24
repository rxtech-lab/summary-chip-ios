CREATE TABLE `podcast_publications` (
	`id` text PRIMARY KEY NOT NULL,
	`owner_id` text NOT NULL,
	`episode_key` text NOT NULL,
	`day` text NOT NULL,
	`visibility` text NOT NULL,
	`ttl_days` integer,
	`expires_at` integer,
	FOREIGN KEY (`owner_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `podcast_publications_episode_idx` ON `podcast_publications` (`owner_id`,`episode_key`);