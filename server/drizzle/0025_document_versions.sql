CREATE TABLE `document_versions` (
	`summary_id` text NOT NULL,
	`version` integer NOT NULL,
	`kind` text NOT NULL,
	`content` text NOT NULL,
	`actor` text NOT NULL,
	`restored_from` integer,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	PRIMARY KEY(`summary_id`, `version`),
	FOREIGN KEY (`summary_id`) REFERENCES `summaries`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
-- Every existing item starts its history at version 1, as it is now.
INSERT INTO `document_versions` (`summary_id`, `version`, `kind`, `content`, `actor`, `created_at`)
SELECT s.`id`, 1, s.`kind`,
	CASE WHEN s.`kind` = 'trip' THEN json_object('document', json(t.`document`))
	ELSE json_object('title', s.`title`, 'summary', s.`summary`, 'highlights', json(s.`highlights`), 'category', s.`category`,
		'tags', json(s.`tags`), 'keywords', json(s.`keywords`)) END,
	'owner', coalesce(t.`updated_at`, s.`updated_at`)
FROM `summaries` s LEFT JOIN `trips` t ON t.`summary_id` = s.`id`
WHERE s.`kind` <> 'trip' OR t.`summary_id` IS NOT NULL;
