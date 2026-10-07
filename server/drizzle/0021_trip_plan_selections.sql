CREATE TABLE `trip_plan_selections` (
	`trip_id` text NOT NULL,
	`user_id` text NOT NULL,
	`selections` text NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	PRIMARY KEY(`trip_id`, `user_id`),
	FOREIGN KEY (`trip_id`) REFERENCES `trips`(`summary_id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
