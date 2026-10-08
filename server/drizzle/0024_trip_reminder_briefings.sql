CREATE TABLE `trip_reminder_briefings` (
	`trip_id` text NOT NULL,
	`input_hash` text NOT NULL,
	`body` text NOT NULL,
	`expires_at` integer NOT NULL,
	PRIMARY KEY(`trip_id`, `input_hash`),
	FOREIGN KEY (`trip_id`) REFERENCES `trips`(`summary_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `trip_briefings_expiry_idx` ON `trip_reminder_briefings` (`expires_at`);