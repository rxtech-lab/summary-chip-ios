CREATE TABLE `podcast_drafts` (
 `key` text PRIMARY KEY NOT NULL REFERENCES `podcast_episodes`(`key`) ON DELETE CASCADE,
 `revision` integer DEFAULT 0 NOT NULL,
 `files` text NOT NULL
);
