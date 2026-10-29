ALTER TABLE `podcast_plans` ADD `created_at` integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE `podcast_plans` ADD `updated_at` integer DEFAULT 0 NOT NULL;--> statement-breakpoint
CREATE INDEX `podcast_plans_owner_idx` ON `podcast_plans` (`owner_id`,`confirmed`,`updated_at`);
