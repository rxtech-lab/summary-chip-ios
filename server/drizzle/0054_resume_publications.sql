CREATE TABLE resume_assets (
  id TEXT PRIMARY KEY NOT NULL,
  family_id TEXT NOT NULL REFERENCES summaries(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)), bytes BLOB NOT NULL, mime_type TEXT NOT NULL, source_key TEXT NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX resume_asset_source_idx ON resume_assets(family_id,source_key);
--> statement-breakpoint
CREATE TABLE resume_previews (
  id TEXT PRIMARY KEY NOT NULL,
  family_id TEXT NOT NULL REFERENCES summaries(id) ON DELETE CASCADE,
  revision_token TEXT NOT NULL, language TEXT NOT NULL, variant_id TEXT,
  missing_translation_paths TEXT NOT NULL, html TEXT NOT NULL, document TEXT NOT NULL, presentation TEXT NOT NULL, asset_id TEXT REFERENCES resume_assets(id),
  created_at INTEGER NOT NULL
);
--> statement-breakpoint
CREATE TABLE resume_artifact_chunks (
  preview_id TEXT NOT NULL REFERENCES resume_previews(id) ON DELETE CASCADE,
  format TEXT NOT NULL, ordinal INTEGER NOT NULL, bytes BLOB NOT NULL,
  PRIMARY KEY(preview_id,format,ordinal)
);
--> statement-breakpoint
CREATE TABLE resume_publications (
  link_id TEXT PRIMARY KEY NOT NULL REFERENCES share_links(id) ON DELETE CASCADE,
  preview_id TEXT NOT NULL REFERENCES resume_previews(id)
);
--> statement-breakpoint
CREATE TABLE resume_publication_writes (
  family_id TEXT NOT NULL REFERENCES summaries(id) ON DELETE CASCADE,
  key TEXT NOT NULL, digest TEXT NOT NULL, result TEXT NOT NULL, PRIMARY KEY(family_id,key)
);
--> statement-breakpoint
CREATE TABLE resume_publication_views (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  link_id TEXT NOT NULL REFERENCES resume_publications(link_id) ON DELETE CASCADE,
  viewed_at INTEGER NOT NULL, PRIMARY KEY(user_id,link_id)
);
--> statement-breakpoint
CREATE TRIGGER share_links_limit BEFORE INSERT ON share_links
WHEN (SELECT count(*) FROM share_links WHERE summary_id=NEW.summary_id) >= 20
BEGIN SELECT RAISE(ABORT,'share_links_limit'); END;
--> statement-breakpoint
CREATE TABLE resume_render_leases (
  id TEXT PRIMARY KEY NOT NULL, family_id TEXT NOT NULL REFERENCES summaries(id) ON DELETE CASCADE,
  revision_token TEXT NOT NULL, asset_id TEXT REFERENCES resume_assets(id), expires_at INTEGER NOT NULL
);
--> statement-breakpoint
CREATE TRIGGER resume_private_insert BEFORE INSERT ON summaries
WHEN NEW.kind='resume' AND NEW.visibility<>'private'
BEGIN SELECT RAISE(ABORT,'resume_families_are_private'); END;
--> statement-breakpoint
CREATE TRIGGER resume_private_update BEFORE UPDATE OF kind,visibility ON summaries
WHEN NEW.kind='resume' AND NEW.visibility<>'private'
BEGIN SELECT RAISE(ABORT,'resume_families_are_private'); END;
