CREATE TABLE `summary_embeddings` (
	`summary_id` text PRIMARY KEY NOT NULL,
	`model` text NOT NULL,
	`embedding` blob NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	FOREIGN KEY (`summary_id`) REFERENCES `summaries`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `summary_embeddings_model_idx` ON `summary_embeddings` (`model`);