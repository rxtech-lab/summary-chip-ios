CREATE TABLE `resume_editions` (
	`family_id` text NOT NULL,
	`language` text NOT NULL,
	PRIMARY KEY(`family_id`, `language`),
	FOREIGN KEY (`family_id`) REFERENCES `resume_families`(`id`) ON UPDATE no action ON DELETE cascade,
	CONSTRAINT "resume_supported_language" CHECK("resume_editions"."language" in ('en','zh-Hans','zh-Hant','ja','ko','es','fr','de'))
);
--> statement-breakpoint
CREATE TABLE `resume_families` (
	`id` text PRIMARY KEY NOT NULL,
	`source_language` text NOT NULL,
	`revision` integer NOT NULL,
	FOREIGN KEY (`id`) REFERENCES `summaries`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `resume_receipts` (
	`owner_id` text NOT NULL,
	`key` text NOT NULL,
	`family_id` text NOT NULL,
	`request_hash` text NOT NULL,
	`result` text NOT NULL,
	PRIMARY KEY(`owner_id`, `key`),
	FOREIGN KEY (`owner_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`family_id`) REFERENCES `resume_families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `resume_revisions` (
	`family_id` text NOT NULL,
	`component` text NOT NULL,
	`revision` integer NOT NULL,
	`payload` text NOT NULL,
	`origin` text NOT NULL,
	`language` text NOT NULL,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	PRIMARY KEY(`family_id`, `component`, `revision`),
	FOREIGN KEY (`family_id`) REFERENCES `resume_families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `resume_variants` (
	`id` text PRIMARY KEY NOT NULL,
	`family_id` text NOT NULL,
	`company` text NOT NULL,
	`target_role` text,
	`job_description` text,
	FOREIGN KEY (`family_id`) REFERENCES `resume_families`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `resume_variants_family` ON `resume_variants` (`family_id`);
--> statement-breakpoint
CREATE TRIGGER resume_summary_private_insert BEFORE INSERT ON summaries
WHEN NEW.kind='resume' AND NEW.visibility!='private'
BEGIN SELECT RAISE(ABORT,'resume_requires_private_summary'); END;
--> statement-breakpoint
CREATE TRIGGER resume_summary_private_update BEFORE UPDATE OF visibility,kind ON summaries
WHEN (NEW.kind='resume' AND NEW.visibility!='private') OR (OLD.kind='resume' AND NEW.kind!='resume')
BEGIN SELECT RAISE(ABORT,'resume_requires_private_summary'); END;
--> statement-breakpoint
CREATE TRIGGER resume_revision_immutable BEFORE UPDATE ON resume_revisions
BEGIN SELECT RAISE(ABORT,'resume_revision_is_immutable'); END;
--> statement-breakpoint
CREATE INDEX resume_receipts_family ON resume_receipts(family_id);
