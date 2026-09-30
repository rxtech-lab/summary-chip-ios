CREATE TABLE `summaries` (
	`id` text PRIMARY KEY NOT NULL,
	`slug` text NOT NULL,
	`owner_id` text NOT NULL,
	`source_type` text NOT NULL,
	`source_url` text,
	`source_title` text,
	`site_name` text,
	`source_file_key` text,
	`content_excerpt` text DEFAULT '' NOT NULL,
	`title` text NOT NULL,
	`summary` text NOT NULL,
	`highlights` text NOT NULL,
	`category` text NOT NULL,
	`tags` text NOT NULL,
	`keywords` text NOT NULL,
	`language` text NOT NULL,
	`theme` text NOT NULL,
	`og_headline` text,
	`image_style` text DEFAULT 'graphic' NOT NULL,
	`og_image_key` text,
	`visibility` text DEFAULT 'public' NOT NULL,
	`ttl_days` integer,
	`expires_at` integer,
	`view_count` integer DEFAULT 0 NOT NULL,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	FOREIGN KEY (`owner_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `summaries_slug_unique` ON `summaries` (`slug`);--> statement-breakpoint
CREATE INDEX `summaries_owner_created_idx` ON `summaries` (`owner_id`,`created_at`,`id`);--> statement-breakpoint
CREATE INDEX `summaries_expires_idx` ON `summaries` (`expires_at`);--> statement-breakpoint
CREATE TABLE `summary_tags` (
	`summary_id` text NOT NULL,
	`tag` text NOT NULL,
	PRIMARY KEY(`summary_id`, `tag`),
	FOREIGN KEY (`summary_id`) REFERENCES `summaries`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `summary_tags_tag_idx` ON `summary_tags` (`tag`);--> statement-breakpoint
CREATE TABLE `summary_views` (
	`user_id` text NOT NULL,
	`summary_id` text NOT NULL,
	`viewed_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	PRIMARY KEY(`user_id`, `summary_id`),
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`summary_id`) REFERENCES `summaries`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `summary_views_user_viewed_idx` ON `summary_views` (`user_id`,`viewed_at`);--> statement-breakpoint
CREATE INDEX `summary_views_summary_idx` ON `summary_views` (`summary_id`);--> statement-breakpoint
CREATE TABLE `uploads` (
	`key` text PRIMARY KEY NOT NULL,
	`owner_id` text NOT NULL,
	`filename` text NOT NULL,
	`byte_size` integer NOT NULL,
	`summary_id` text,
	`attached_at` integer,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	FOREIGN KEY (`owner_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `uploads_orphan_idx` ON `uploads` (`attached_at`,`created_at`);--> statement-breakpoint
CREATE TABLE `users` (
	`id` text PRIMARY KEY NOT NULL,
	`email` text,
	`name` text,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL
);
