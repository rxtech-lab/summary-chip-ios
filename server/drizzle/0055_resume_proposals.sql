CREATE TABLE `resume_proposals` (
	`id` text PRIMARY KEY NOT NULL,
	`family_id` text NOT NULL,
	`owner_id` text NOT NULL,
	`request_key` text NOT NULL,
	`input` text NOT NULL,
	`target_token` text,
	`status` text NOT NULL,
	`findings` text DEFAULT '[]' NOT NULL,
	`error` text,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`family_id`) REFERENCES `summaries`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`owner_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	CONSTRAINT "resume_proposal_status" CHECK("resume_proposals"."status" in ('queued','running','ready','failed'))
);

--> statement-breakpoint
CREATE UNIQUE INDEX `resume_proposals_request_key` ON `resume_proposals` (`owner_id`,`request_key`);
