ALTER TABLE `users` ADD `deletion_scheduled_at` integer;--> statement-breakpoint
ALTER TABLE `users` ADD `deletion_requested_at` integer;--> statement-breakpoint
ALTER TABLE `users` ADD `deletion_request_id` text;--> statement-breakpoint
CREATE INDEX `users_deletion_scheduled_idx` ON `users` (`deletion_scheduled_at`);