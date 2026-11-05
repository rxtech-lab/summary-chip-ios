UPDATE summaries SET kind = 'audiobook'
WHERE kind = 'podcast'
AND EXISTS (
  SELECT 1 FROM podcast_episodes
  WHERE podcast_episodes.summary_id = summaries.id
    AND json_extract(podcast_episodes.document, '$.format') = 'audiobook'
)
AND NOT EXISTS (
  SELECT 1 FROM podcast_episodes
  WHERE podcast_episodes.summary_id = summaries.id
    AND COALESCE(json_extract(podcast_episodes.document, '$.format'), 'podcast') <> 'audiobook'
);
