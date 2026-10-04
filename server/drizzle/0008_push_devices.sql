CREATE TABLE `push_devices` (
	`installation_id` text PRIMARY KEY NOT NULL,
	`owner_id` text NOT NULL,
	`token` text NOT NULL,
	`environment` text NOT NULL,
	`platform` text NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	FOREIGN KEY (`owner_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `push_devices_token_environment_idx` ON `push_devices` (`token`,`environment`);--> statement-breakpoint
CREATE INDEX `push_devices_owner_idx` ON `push_devices` (`owner_id`);