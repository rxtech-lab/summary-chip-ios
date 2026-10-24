-- The language of a chip's kept source document, which can differ from the chip's own (agents may
-- write an English chip from a Japanese article). Null = the chip's language.
ALTER TABLE `summaries` ADD `source_language` text;
