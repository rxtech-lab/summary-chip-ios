CREATE TABLE `editorial_scores` (
	`summary_id` text PRIMARY KEY NOT NULL,
	`owner_id` text NOT NULL,
	`score` integer NOT NULL,
	`is_editors_pick` integer NOT NULL,
	`ranked_at` integer NOT NULL,
	FOREIGN KEY (`summary_id`) REFERENCES `summaries`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`owner_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `editorial_scores_owner_pick_idx` ON `editorial_scores` (`owner_id`,`is_editors_pick`);
--> statement-breakpoint
INSERT INTO editorial_scores (summary_id, owner_id, score, is_editors_pick, ranked_at)
SELECT s.id, r.owner_id, CAST(j.value AS INTEGER), CAST(j.value AS INTEGER) >= 80, r.started_at
FROM headline_rankings r, json_each(r.scores) j
JOIN summaries s ON s.id = j.key AND s.owner_id = r.owner_id
WHERE s.kind IN ('summary', 'podcast') AND j.type = 'integer' AND j.value BETWEEN 0 AND 100;
