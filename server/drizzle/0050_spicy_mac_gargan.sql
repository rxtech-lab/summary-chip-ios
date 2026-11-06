CREATE TABLE `author_follows` (
	`follower_id` text NOT NULL,
	`author_id` text NOT NULL,
	PRIMARY KEY(`follower_id`, `author_id`),
	FOREIGN KEY (`follower_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`author_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `marketplace_publications` (
	`summary_id` text PRIMARY KEY NOT NULL,
	`published_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	FOREIGN KEY (`summary_id`) REFERENCES `summaries`(`id`) ON UPDATE no action ON DELETE cascade
);
