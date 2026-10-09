# Change Log

This file documents all significant changes made to the Ballerina `ai.aws.s3` package across releases.

## [Unreleased]

### Added

- `TextDataLoader`, an `ai:DataLoader` that loads text documents from AWS S3 buckets, extracting PDF, Word (`.docx`), PowerPoint (`.pptx`) and Excel (`.xlsx`) content in memory.
- `VectorStore`, an `ai:VectorStore` backed by an Amazon S3 Vectors index.
