# Issue #159: Upload status as SSE stream (Elixir)

## Summary
Replace the polling-based `GET /api/upload/:image_id/status` endpoint with a Server-Sent Events
stream at `GET /api/upload/:image_id/stream`. The new endpoint holds the connection open, sends
the current status immediately (to handle already-completed jobs), and pushes the terminal event
when `IdentifyBookJob` finishes. The old status endpoint and its controller action are removed in
this PR.

## User Stories
US-1.1.1, US-1.1.2, US-1.1.3, US-1.1.4, US-1.1.5, US-1.1.6, US-1.1.7, US-1.1.8

## Goal
Zero redundant DB hits after the first status check. A connected client receives exactly one push
event (resolved or rejected) and then closes the connection. The 150-poll / 2-second loop in the
Elm frontend (handled in #160) is eliminated entirely.

## Technical Requirements

### 1. New SSE endpoint
Route: `GET /api/upload/:image_id/stream`  
File: `apps/core/lib/core_web/router.ex`
- Add under the `:authenticated` scope (same auth pipeline as the old status route).
- JWT token delivered as `?token=<jwt>` query parameter because browser `EventSource` cannot
  set custom headers. Use a dedicated `AuthTokenPlug` or override Guardian extraction to read
  from query params when no `Authorization` header is present. **Note:** tokens in query params
  may appear in access logs — document this tradeoff in a module comment.

### 2. Controller action
File: `apps/core/lib/core_web/controllers/upload_controller.ex`

```elixir
def stream(conn, %{"image_id" => image_id}) do
  # 1. Validate image_id is a UUID; return 400 otherwise.
  # 2. Fetch UploadedImage; return 404 if missing.
  # 3. Return 403 if image.user_id != current_user.id.
  # 4. Subscribe to PubSub BEFORE reading current status (avoids the
  #    race where the job completes between the read and the subscribe).
  Phoenix.PubSub.subscribe(Core.PubSub, "upload:#{image_id}")
  # 5. If status is already "resolved" or "rejected": send the terminal
  #    event immediately and close without waiting on PubSub.
  # 6. If status is "pending": open a chunked SSE response and block in
  #    `receive` until {:upload_complete, payload} arrives (max 60s).
  #    Send a `data: {"type":"heartbeat"}\n\n` every 15s to keep the
  #    connection alive through proxies.
  # 7. Unsubscribe from PubSub on exit.
end
```

SSE response headers:
```
Content-Type: text/event-stream
Cache-Control: no-cache
X-Accel-Buffering: no
```

SSE event format — use the same payload shape as the old status endpoint
(`ProtoJSON.poll_response/1`) so the Elm decoder needs only a structural change, not a schema
change:
```
data: {"status":"resolved","book_ids":["uuid1","uuid2"],"rejection_reason":null,"is_duplicate":false}\n\n
```

### 3. PubSub broadcast from IdentifyBookJob
File: `apps/core/lib/stacks/workers/identify_book_job.ex`

After updating the DB in `mark_resolved/4` and `mark_rejected/3`, broadcast:
```elixir
Phoenix.PubSub.broadcast(
  Core.PubSub,
  "upload:#{image_id}",
  {:upload_complete, %{status: "resolved", book_ids: book_ids}}
)
```
```elixir
Phoenix.PubSub.broadcast(
  Core.PubSub,
  "upload:#{image_id}",
  {:upload_complete, %{status: "rejected", rejection_reason: reason}}
)
```

### 4. Remove status endpoint
- Remove `get "/upload/:image_id/status"` from `router.ex`.
- Remove `UploadController.status/2` action.
- Remove associated tests from `upload_pipeline_test.exs` (Suite 3 and the 401 test for the
  status path — they will be replaced by SSE tests in this issue).

### 5. Tests
File: `apps/core/test/stacks/upload_pipeline_test.exs`
- `stream/2` returns `200 text/event-stream` for a valid pending image (GET request with token
  query param, check content-type header).
- `stream/2` immediately sends terminal event when image already resolved.
- `stream/2` pushes event when IdentifyBookJob completes after connection opens.
- `stream/2` returns 401 when no token provided.
- `stream/2` returns 403 when image belongs to a different user.
- `stream/2` returns 404 for unknown image_id.

## Reviewer Context
- `ProtoJSON.poll_response/1` is the existing serialiser for the status payload — reuse it in
  the SSE action to keep the JSON shape identical so Elm (#160) only changes the transport, not
  the decoder.
- `Core.PubSub` is the application's PubSub process; it is started in `Core.Application`.
- The `authenticated` Guardian pipeline reads JWT from the `Authorization` header; you will
  need to extend it (or add a separate plug) to also accept `?token=` for the SSE route.
- `IdentifyBookJob` currently calls `mark_resolved/4` and `mark_rejected/3` — add broadcasts
  inside those private functions, not in `perform/2`, to keep the emit logic co-located with
  the DB update.

## Definition of Done
- [ ] `GET /api/upload/:image_id/stream` added to router with `:authenticated` guard
- [ ] JWT accepted via `?token=` query param for SSE route
- [ ] Controller streams SSE, handles already-resolved/rejected images immediately
- [ ] Heartbeat sent every 15s to keep proxy connections alive
- [ ] `IdentifyBookJob` broadcasts `{:upload_complete, payload}` to `"upload:#{image_id}"` on resolve AND reject
- [ ] `GET /api/upload/:image_id/status` route removed
- [ ] `UploadController.status/2` removed
- [ ] All old status-endpoint tests removed
- [ ] New SSE tests pass: 200, 401, 403, 404, already-resolved, push-on-complete
- [ ] `mix test` green, `mix credo --strict` clean

## Dependencies
#160 (Elm EventSource port) depends on this issue. Implement #159 first on the shared branch.

## Agent Assignment
elixir-agent
