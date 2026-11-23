# RichDocumentEditor

A reusable Swift package for iOS, macOS and visionOS Markdown composition, pasted images,
photo/file selection, and direct signed S3 uploads with byte progress. It has no Chippy dependency.

Embed `RichMarkdownEditor(markdown:onUploadingChanged:upload:)` in a sheet. Its upload closure receives
image bytes, a filename, MIME type, and progress callback. The host creates a signed upload ticket,
calls `DirectImageUpload.upload(_:request:progress:)`, then finalizes the upload using the returned key.
Return the resulting permanent image URL; the editor inserts a Markdown image reference.
Disable the sheet's toolbar actions while `onUploadingChanged` is true.

The companion `server/packages/rich-document-media` module exports `compressDocumentImage` for
server-side WebP encoding (quality 82, maximum 2048px, auto-orientation and metadata removal).
Compression happens after the original bytes reach S3, so the app API only receives small JSON
requests. Chippy's authenticated finalization endpoint checks upload ownership and completion.
