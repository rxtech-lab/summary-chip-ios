CREATE TABLE `summary_likes` (
	`user_id` text NOT NULL,
	`summary_id` text NOT NULL,
	`liked_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	PRIMARY KEY(`user_id`, `summary_id`),
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`summary_id`) REFERENCES `summaries`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `summary_likes_user_liked_idx` ON `summary_likes` (`user_id`,`liked_at`);--> statement-breakpoint
CREATE INDEX `summary_likes_summary_idx` ON `summary_likes` (`summary_id`);