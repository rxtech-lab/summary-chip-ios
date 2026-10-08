CREATE TABLE `papers` (
	`summary_id` text PRIMARY KEY NOT NULL,
	`files` text NOT NULL,
	`main_file` text NOT NULL,
	`compiler` text DEFAULT 'pdflatex' NOT NULL,
	`revision` integer DEFAULT 0 NOT NULL,
	`versioned_revision` integer DEFAULT 0 NOT NULL,
	`pdf_hash` text,
	`pdf_key` text,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	FOREIGN KEY (`summary_id`) REFERENCES `summaries`(`id`) ON UPDATE no action ON DELETE cascade
);
