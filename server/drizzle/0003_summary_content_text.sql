ALTER TABLE `summaries` ADD `content_text` text DEFAULT '' NOT NULL;--> statement-breakpoint
UPDATE `summaries` SET `content_text` = `content_excerpt`;
