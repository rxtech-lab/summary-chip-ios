CREATE TABLE IF NOT EXISTS `trip_translations` (
	`summary_id` text NOT NULL,
	`language` text NOT NULL,
	`strings` text NOT NULL,
	`revision` integer NOT NULL,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	PRIMARY KEY(`summary_id`, `language`),
	FOREIGN KEY (`summary_id`) REFERENCES `summaries`(`id`) ON UPDATE no action ON DELETE cascade
);
