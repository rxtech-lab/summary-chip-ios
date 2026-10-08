CREATE TABLE `paper_reference_checks` (
	`summary_id` text NOT NULL,
	`hash` text NOT NULL,
	`status` text DEFAULT 'checking' NOT NULL,
	`issue` text,
	`message` text,
	`started_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`checked_at` integer,
	PRIMARY KEY(`summary_id`, `hash`),
	FOREIGN KEY (`summary_id`) REFERENCES `papers`(`summary_id`) ON UPDATE no action ON DELETE cascade
);
