ALTER TABLE `summaries` ADD `source` text DEFAULT 'web' NOT NULL;--> statement-breakpoint
UPDATE `summaries` SET `source` = `source_type` WHERE `source_type` IN ('pdf', 'text');
