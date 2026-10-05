CREATE TABLE `flight_live_activities` (
	`flight_id` text NOT NULL,
	`installation_id` text NOT NULL,
	`owner_id` text NOT NULL,
	`token` text NOT NULL,
	`environment` text NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	PRIMARY KEY(`flight_id`, `installation_id`),
	FOREIGN KEY (`flight_id`) REFERENCES `flights`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`owner_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `flight_subscriptions` (
	`trip_id` text NOT NULL,
	`transport_id` text NOT NULL,
	`option_id` text NOT NULL,
	`segment_index` integer NOT NULL,
	`flight_id` text NOT NULL,
	`owner_id` text NOT NULL,
	`live_activity_started_at` integer,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	PRIMARY KEY(`trip_id`, `transport_id`, `option_id`, `segment_index`),
	FOREIGN KEY (`trip_id`) REFERENCES `summaries`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`flight_id`) REFERENCES `flights`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`owner_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `flight_subscriptions_flight_idx` ON `flight_subscriptions` (`flight_id`);--> statement-breakpoint
CREATE INDEX `flight_subscriptions_owner_idx` ON `flight_subscriptions` (`owner_id`);--> statement-breakpoint
CREATE TABLE `flights` (
	`id` text PRIMARY KEY NOT NULL,
	`flight_number` text NOT NULL,
	`date` text NOT NULL,
	`provider` text NOT NULL,
	`state` text DEFAULT 'pending' NOT NULL,
	`data` text,
	`departure_at` integer,
	`arrival_at` integer,
	`landed_at` integer,
	`alert_state` text,
	`fetched_at` integer,
	`tracking_state` text DEFAULT 'idle' NOT NULL,
	`tracking_run_id` text,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL
);
--> statement-breakpoint
CREATE INDEX `flights_tracking_idx` ON `flights` (`tracking_state`);--> statement-breakpoint
ALTER TABLE `push_devices` ADD `live_activity_start_token` text;