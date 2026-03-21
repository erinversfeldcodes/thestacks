# Issue #064: Cloudflare R2 Object Storage Migration

## Summary
Migrate image storage from Oban job args (base64 in PostgreSQL) to Cloudflare R2 with presigned URLs. Upload images write to R2; the vision service fetches directly from R2 via presigned URL — image bytes never transit Fly.io machines after the initial upload.

## User Stories
US-1.1.1 (upload), US-8.4 (image retention — 30-day TTL)

## Goal
Uploaded images are stored in R2 with a 30-day TTL. The `IdentifyBookJob` worker generates a short-lived presigned GET URL and passes it to Modal. Book cover thumbnails are permanently stored in R2. Marketplace listing photos are stored in R2. The image retention job deletes expired R2 objects and emits `image.purged` events. The missing-purge alarm detects silent retention failures.

## Technical Requirements

**R2 bucket layout:**
```
stacks-images/
  uploads/{image_id}          — 30-day TTL, private
  covers/{isbn}-cover.jpg     — permanent, public-readable via CDN
  marketplace/{listing_id}/{n}.jpg — permanent while listing active, public-readable
```

**`Stacks.Storage` context (new):**
- `upload/2` — writes bytes to R2 `uploads/` prefix, returns storage key
- `presigned_url/2` — generates short-lived (15 min) GET URL for a storage key
- `delete/1` — deletes an R2 object
- `upload_cover/2` — writes cover thumbnail to `covers/` prefix
- Uses `ExAws.S3` with R2-compatible endpoint configuration

**Upload pipeline changes:**
- `Books.store_upload/2` — writes to R2 instead of base64-encoding into Oban job args
- `IdentifyBookJob` — generates presigned URL, passes to Modal instead of base64 payload
- Modal vision service — updated to accept `image_url` parameter (presigned URL) instead of `image_b64`
- Fallback: if `STORAGE_BACKEND=local` (dev/test), use local filesystem (`tmp/uploads/`)

**Image retention changes:**
- `ImageRetentionJob` — queries `uploaded_images` where `expires_at < now()`, deletes R2 objects, emits `image.purged` event
- Missing-purge alarm: SQL query from tech-arch (images past TTL without corresponding purge event) — run daily, alert on any result

**Cover image sourcing:**
- When a book edition is created, fetch cover from Open Library/Google Books and store in R2 `covers/`
- `book_editions.cover_image_url` points to R2 CDN URL (not Open Library URL)

**Configuration:**
- `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET_NAME` env vars
- `STORAGE_BACKEND` env var: `r2` (production) or `local` (dev/test)

**Mocking:**
- `Stacks.Storage` defined as a behaviour (`ObjectStorage` behaviour already exists per tech-arch)
- Test mock: `MockObjectStorage` via Mox — no real R2 calls in tests

## Definition of Done
- [ ] Upload writes to R2 in production, local filesystem in dev/test
- [ ] `IdentifyBookJob` passes presigned URL to Modal (not base64)
- [ ] Modal vision service accepts `image_url` parameter
- [ ] Cover images stored in R2 CDN-accessible path
- [ ] `ImageRetentionJob` deletes expired R2 objects and emits `image.purged`
- [ ] Missing-purge alarm query runs daily; alerts on orphaned images
- [ ] `STORAGE_BACKEND=local` works for dev/test without R2 credentials
- [ ] `mix test` passes with mocked storage
- [ ] No base64 image data in Oban job args

## Dependencies
Issue #046 (upload pipeline must work with works/editions before migrating storage). Best done after core upload flow is stable — late in the sequence.

## Agent Assignment
elixir-agent + python-agent (vision service URL param)

## Progress Notes
