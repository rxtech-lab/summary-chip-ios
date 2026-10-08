CREATE TABLE `trip_weather` (
	`trip_id` text PRIMARY KEY NOT NULL,
	`provider` text,
	`data` text,
	`alert_state` text,
	`fetched_at` integer,
	`tracking_state` text DEFAULT 'idle' NOT NULL,
	`tracking_run_id` text,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	FOREIGN KEY (`trip_id`) REFERENCES `summaries`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `trip_weather_tracking_idx` ON `trip_weather` (`tracking_state`);--> statement-breakpoint
ALTER TABLE `push_devices` ADD `time_zone` text;