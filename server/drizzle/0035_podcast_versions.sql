CREATE TABLE `podcast_episodes` (
 `key` text PRIMARY KEY NOT NULL,
 `owner_id` text NOT NULL REFERENCES `users`(`id`) ON DELETE CASCADE,
 `day_start` integer NOT NULL,
 `day_end` integer NOT NULL,
 `document` text NOT NULL,
 `is_default` integer DEFAULT 0 NOT NULL,
 `deleted` integer DEFAULT 0 NOT NULL,
 `summary_id` text REFERENCES `summaries`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE INDEX `podcast_episodes_day_idx` ON `podcast_episodes` (`owner_id`,`day_start`,`day_end`);
