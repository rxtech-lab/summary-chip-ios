CREATE TABLE `mini_app_connection_grants` (
	`connection_id` text NOT NULL,
	`email` text NOT NULL,
	`operations` text NOT NULL,
	PRIMARY KEY(`connection_id`, `email`),
	FOREIGN KEY (`connection_id`) REFERENCES `mini_app_connections`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `mini_app_connections` (
	`id` text PRIMARY KEY NOT NULL,
	`app_id` text NOT NULL,
	`user_id` text NOT NULL,
	`connector` text NOT NULL,
	`shared` integer DEFAULT false NOT NULL,
	`fingerprint` text NOT NULL,
	`secret` text NOT NULL,
	`status` text DEFAULT 'connected' NOT NULL,
	`revision` integer DEFAULT 0 NOT NULL,
	`refresh_lease` integer DEFAULT 0 NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	FOREIGN KEY (`app_id`) REFERENCES `mini_apps`(`summary_id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `mini_connection_user_idx` ON `mini_app_connections` (`app_id`,`user_id`,`connector`,`shared`);--> statement-breakpoint
CREATE TABLE `mini_app_members` (
	`app_id` text NOT NULL,
	`email` text NOT NULL,
	`permissions` text NOT NULL,
	PRIMARY KEY(`app_id`, `email`),
	FOREIGN KEY (`app_id`) REFERENCES `mini_apps`(`summary_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `mini_app_oauth` (
	`state_hash` text PRIMARY KEY NOT NULL,
	`app_id` text NOT NULL,
	`user_id` text NOT NULL,
	`connector` text NOT NULL,
	`shared` integer NOT NULL,
	`fingerprint` text NOT NULL,
	`secret` text NOT NULL,
	`expires_at` integer NOT NULL,
	FOREIGN KEY (`app_id`) REFERENCES `mini_apps`(`summary_id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `mini_oauth_expiry_idx` ON `mini_app_oauth` (`expires_at`);--> statement-breakpoint
CREATE TABLE `mini_app_records` (
	`id` text PRIMARY KEY NOT NULL,
	`app_id` text NOT NULL,
	`collection` text NOT NULL,
	`partition` text NOT NULL,
	`user_id` text,
	`data` text NOT NULL,
	`revision` integer DEFAULT 0 NOT NULL,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	FOREIGN KEY (`app_id`) REFERENCES `mini_apps`(`summary_id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `mini_records_partition_idx` ON `mini_app_records` (`app_id`,`collection`,`partition`,`id`);--> statement-breakpoint
CREATE TABLE `mini_app_runs` (
	`id` text PRIMARY KEY NOT NULL,
	`app_id` text NOT NULL,
	`user_id` text NOT NULL,
	`key` text NOT NULL,
	`fingerprint` text NOT NULL,
	`status` text NOT NULL,
	`result` text,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	FOREIGN KEY (`app_id`) REFERENCES `mini_apps`(`summary_id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `mini_run_key_idx` ON `mini_app_runs` (`app_id`,`user_id`,`key`);--> statement-breakpoint
CREATE INDEX `mini_run_time_idx` ON `mini_app_runs` (`created_at`);--> statement-breakpoint
CREATE TABLE `mini_apps` (
	`summary_id` text PRIMARY KEY NOT NULL,
	`document` text NOT NULL,
	`revision` integer DEFAULT 0 NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	FOREIGN KEY (`summary_id`) REFERENCES `summaries`(`id`) ON UPDATE no action ON DELETE cascade
);
