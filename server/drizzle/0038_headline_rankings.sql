CREATE TABLE `headline_rankings` (
	`owner_id` text PRIMARY KEY NOT NULL,
	`revision` text NOT NULL,
	`started_at` integer NOT NULL,
	`scores` text NOT NULL,
	FOREIGN KEY (`owner_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
