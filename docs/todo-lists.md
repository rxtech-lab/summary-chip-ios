# Todo lists

Todo lists are `kind: todo_list` library chips, available from **New → Todo List**. They open a
native checklist. Owners add items inline from the trailing **New Item** row. Return adds an item and
leaves the field ready for the next one. Shift+Return adds a line within the title. Pasting multiple
lines of plain text into an empty field creates one item per line. Owners can also edit titles in
place, swipe to complete or delete, and drag to reorder. Inline edits save in the background. List metadata, item
details and Markdown descriptions use dedicated sheets.
The chip preview shows completion counts, the list deadline, and up to three unfinished items.
The description editor supports Markdown preview, image paste, Photos and file import.
Paste an image or file into an item field or select it from the attachment menu. Each item holds up
to 20 attachments, up to 25 MiB each. Submitting a file without a title uses its filename as the title.

Each document contains `title`, `description` (Markdown), `deadline` (an ISO instant with a timezone),
and `items`: `{ id, title, deadline, completed, attachments }`. Attachments contain `id`, `url`,
`name`, `contentType`, and `size` in bytes. Older items without `attachments` decode as an empty
array. Item ids must be unique and stable across edits.
Empty lists count as completed. Each list permits up to 500 items and a 100,000-character description.

## API and MCP

- `GET/POST /api/v1/todo-lists`: list owned lists or create one (`{ document, visibility? }`, private by default).
- `GET/PUT/DELETE /api/v1/todo-lists/:id`: read, replace using `{ document, revision }`, or delete.
- `create_todo_list`, `list_todo_lists`, `get_todo_list`, `update_todo_list`, `delete_todo_list` expose the same
  operations over MCP. Only creation via MCP queues the **AI created a todo list** alert.
- `finish_document_image_upload` / `POST /api/v1/document-images` consumes an owned `uploadKey` after a
  direct presigned S3 PUT. It returns a lasting WebP URL for Markdown. Image URLs are unguessable bearer
  capabilities; anyone holding one can view it, independently of the parent document's visibility.
- For item attachments, `POST /api/v1/document-files/uploads` issues a presigned PUT URL.
  Upload the bytes directly to storage using the supplied headers, then send the `uploadKey` to
  `POST /api/v1/document-files`. Save the returned `file` object in the item's `attachments`.
  Anyone with the resulting attachment URL can access the file.

Only owners edit or delete. Readers use the existing chip sharing rules. Conflicting saves return
`409 TODO_REVISION_CONFLICT`; reload before applying another edit. Card text and notification events
are committed with the document revision. Updates save document versions; restoring a version creates
a new revision and recomputes its deadline events.

## Notifications and rollout

The existing `/api/cron/trip-notifications` cron also drains the todo outbox every five minutes.
AI creation is additionally dispatched after the creation response. At or after a deadline, the owner
receives an alert for an unfinished list and each unfinished item. Completed, deleted, removed or
rescheduled items are rechecked before sending. Alerts open the list's chip using `summaryId`.
Deadlines use absolute instants, so timezone or daylight-saving changes do not shift stored deadlines.

Each event has a lease and per-installation delivery receipts. Successful deliveries are skipped on
retry; transient failures remain queued and invalid APNs tokens are removed. As with other APNs
outboxes, a crash after APNs acceptance but before receipt persistence can cause redelivery.
The cron must be deployed and APNs configured; OS notification permission is required on each device.

Apply migration `0052_todo_lists.sql` before deploying the server. No production
migration or deployment is performed by the source change itself.
