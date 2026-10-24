-- The existing primary key already indexes (summary_id, hash). Cover the full
-- status poll so it does not need a table lookup for every bibliography entry.
CREATE INDEX `paper_reference_checks_status_cover_idx` ON `paper_reference_checks`
  (`summary_id`, `hash`, `status`, `issue`, `message`, `started_at`, `checked_at`);
