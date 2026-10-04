CREATE TABLE `summary_translations` (
	`summary_id` text NOT NULL,
	`language` text NOT NULL,
	`title` text NOT NULL,
	`summary` text NOT NULL,
	`highlights` text NOT NULL,
	`content_markdown` text,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	PRIMARY KEY(`summary_id`, `language`),
	FOREIGN KEY (`summary_id`) REFERENCES `summaries`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
ALTER TABLE `summaries` ADD `display_language` text;