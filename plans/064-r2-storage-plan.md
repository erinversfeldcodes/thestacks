# Plan: Issue #064 — Cloudflare R2 Object Storage Migration

## Context

Images are currently base64-encoded in Oban job args (stored in PostgreSQL). This bloats the DB and prevents efficient image delivery. The vision sidecar's `/extract` endpoint already supports `image_url`. The `UploadedImage` schema has an unused `storage_path` field ready for R2 keys.

## Key Decisions

1. **ExAws for R2 client** — R2 is S3-compatible, ExAws is the standard Elixir S3 library.
2. **Behaviour-based storage** — `Stacks.Storage` behaviour with R2Storage (prod) and LocalStorage (dev/test). Same pattern as all other external clients.
3. **Presigned URLs for vision sidecar** — worker generates short-lived (15 min) presigned GET URL, passes to Modal. Image bytes never transit Fly.io post-upload.
4. **Upload writes to storage immediately** — `store_upload/2` writes to R2/local before enqueuing IdentifyBookJob. Job args contain `storage_key`, not base64.

## Implementation Steps

### Step 1: Add dependencies
- `{:ex_aws, "~> 2.5"}` and `{:ex_aws_s3, "~> 2.5"}` to `apps/core/mix.exs`

### Step 2: Create Storage behaviour + implementations
- `Stacks.Storage.Behaviour` — `@callback put_object(key, body, opts)`, `@callback get_presigned_url(key, opts)`, `@callback delete_object(key)`
- `Stacks.Storage.R2` — ExAws implementation targeting R2 endpoint
- `Stacks.Storage.Local` — writes to `priv/static/uploads/` in dev, returns file:// URLs
- `Stacks.Storage.Mock` — process dictionary mock for tests

### Step 3: Create `Stacks.Storage` context
- `upload_image/2` — accepts image_id + binary data, stores at `uploads/{image_id}`, returns storage_key
- `get_image_url/1` — generates presigned URL (15 min TTL) for the storage key
- `delete_image/1` — removes object from storage
- `store_cover/2` — stores at `covers/{isbn}-cover.jpg` (permanent, public)

### Step 4: Update upload flow
- `Books.store_upload/2` — after creating UploadedImage, call `Storage.upload_image/2`, set `storage_path` on the record
- `Books.upload_and_identify/3` — pass `storage_key` in job args instead of `image_b64`

### Step 5: Update IdentifyBookJob
- Read `storage_key` from job args (not `image_b64`)
- Call `Storage.get_image_url(storage_key)` for presigned URL
- Pass `image_url` to vision sidecar (not base64)
- Update `Moderation.run_pipeline/1` to accept `image_url` key

### Step 6: Update vision sidecar
- Add `image_url` support to `/classify` endpoint (already on `/extract`)
- Same pattern: download → base64 → model

### Step 7: Update ImageRetentionJob
- After deleting DB records, also call `Storage.delete_image/1` for each expired image
- Emit `image.purged` event with storage_key in payload

### Step 8: Configuration
- `config.exs`: `config :core, :storage, Stacks.Storage.Local` (dev default)
- `test.exs`: `config :core, :storage, Stacks.Storage.Mock`
- `runtime.exs`: R2 credentials from env vars, `config :core, :storage, Stacks.Storage.R2`

## File Inventory

### New files
- `apps/core/lib/stacks/storage.ex` (context)
- `apps/core/lib/stacks/storage/behaviour.ex`
- `apps/core/lib/stacks/storage/r2.ex`
- `apps/core/lib/stacks/storage/local.ex`
- `apps/core/lib/stacks/storage/mock.ex`
- `apps/core/test/stacks/storage_test.exs`

### Modified files
- `apps/core/mix.exs` — add ex_aws deps
- `apps/core/lib/stacks/books.ex` — store_upload writes to storage, upload_and_identify passes storage_key
- `apps/core/lib/stacks/workers/identify_book_job.ex` — read storage_key, get presigned URL
- `apps/core/lib/stacks/moderation.ex` — accept image_url in pipeline context
- `apps/core/lib/stacks/gdpr/image_retention.ex` — delete from storage
- `apps/core/config/config.exs`, `test.exs`, `runtime.exs` — storage config
- `apps/vision/app/main.py` — add image_url to /classify endpoint
