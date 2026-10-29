CREATE TABLE `podcast_plans` (
  `id` text PRIMARY KEY NOT NULL,
  `owner_id` text NOT NULL REFERENCES `users`(`id`) ON DELETE CASCADE,
  `input` text NOT NULL,
  `script` text NOT NULL,
  `revision` integer DEFAULT 0 NOT NULL,
  `generating_until` integer DEFAULT 0 NOT NULL,
  `confirmed` integer DEFAULT false NOT NULL
);
