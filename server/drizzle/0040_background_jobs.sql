CREATE TABLE background_jobs (
  id text PRIMARY KEY NOT NULL,
  owner_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  episode_key text NOT NULL REFERENCES podcast_episodes(key) ON DELETE CASCADE,
  document text NOT NULL,
  created_at integer NOT NULL,
  notified_at integer
);
--> statement-breakpoint
CREATE INDEX background_jobs_owner_idx ON background_jobs(owner_id, created_at, id);
