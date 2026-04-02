# Plan: Issues #155, #157, #159, #160 — Upload SSE Migration + Gap Closure

## Overview

Close four open issues on the `chore/close-gaps` branch:
- **#155**: Add missing multi-book cache invalidation test
- **#157**: Fix deprecated dbt `accepted_values` syntax (all 3 instances)
- **#159**: Replace polling status endpoint with SSE stream (Elixir)
- **#160**: Replace polling loop with EventSource in Elm (depends on #159)

Issue #156 is already complete. Issue #158 (SLA assertions) is absorbed into #159, targeting the new stream endpoint.

---

## Phase 1A — #155: Multi-book cache invalidation test

**Agent**: elixir-agent  
**Independent**: yes (parallel with Phase 1B)

### Objective
Add a test proving that when N books are created, each `book.created` event individually invalidates the corresponding cache entry.

### Scope
File: `apps/core/test/stacks/upload_cache_test.exs`

- Prime `BookDetailCache` with two entries via `BookDetailCache.put/2`
- Call `CacheInvalidationHandler.handle_event/1` for each book with event type `book.created`
- Assert `BookDetailCache.get(book_id)` returns `{:miss, id}` for both

Test name (must match exactly): `"book.created for each book in multi-book resolution invalidates each cache entry"`

### Definition of Done
- [ ] Named test passes
- [ ] `mix test apps/core/test/stacks/upload_cache_test.exs` green
- [ ] `mix credo --strict` clean

---

## Phase 1B — #157: dbt schema quality

**Agent**: elixir-agent  
**Independent**: yes (parallel with Phase 1A)

### Objective
Fix all deprecated `arguments:` wrappers in `accepted_values` dbt tests and verify `book_ids` constraint is present.

### Scope
File: `dbt/models/staging/schema.yml`

Fix all three instances of the deprecated `arguments:` wrapper syntax:
1. `stg_books.visibility_tier` — keep values `['public', 'age_gated']` (matches DB ENUM; no migration adds more)
2. `stg_bookshelf_placements.reading_status` — keep existing values unchanged
3. `stg_uploaded_images.status` — keep existing values unchanged

Before (deprecated):
```yaml
- accepted_values:
    arguments:
      values: ['public', 'age_gated']
```

After (correct dbt v1 syntax):
```yaml
- accepted_values:
    values: ['public', 'age_gated']
```

Also verify: `stg_uploaded_images.book_ids` already has `not_null: where: "status = 'resolved'"` — no change needed there.

### Definition of Done
- [ ] All three `accepted_values` entries use correct syntax (no `arguments:` wrapper)
- [ ] Values unchanged from current (only syntax fixed)
- [ ] `dbt compile --project-dir dbt --profiles-dir dbt` passes (if dbt available locally; skip with note if not)
- [ ] `just verify` passes

---

## Phase 2 — #159: Upload status as SSE stream (Elixir)

**Agent**: elixir-agent  
**Depends on**: Phase 1 complete (not a hard dependency, but cleaner)  
**Independent of**: Phase 1A and 1B

### Objective
Replace `GET /api/upload/:image_id/status` polling endpoint with `GET /api/upload/:image_id/stream` SSE stream. Zero redundant DB hits after the first status check.

### Key decisions
- **JWT auth for SSE**: Browser `EventSource` cannot set custom headers. Guardian has no `VerifyParams` plug. Implement `StacksWeb.Plugs.SSEAuthPipeline` — reads `?token=` from query params, calls `Guardian.decode_and_verify/3`, sets current resource on conn. Document the log-leakage tradeoff in a module comment.
- **Integration test coverage**: Both a direct DB assertion AND a real SSE stream HTTP call for integration flows.
- **SLA test** (absorbs #158): `@tag :sla` test asserting `GET /api/upload/:image_id/stream` responds within 100ms.

### Scope

#### 1. New plug — `apps/core/lib/stacks_web/plugs/sse_auth_pipeline.ex`
Custom plug that:
- Reads `conn.query_params["token"]`
- Calls `Stacks.Accounts.Guardian.decode_and_verify(token)`
- On success: loads resource and sets it via `Guardian.Plug.current_resource`
- On failure: returns 401 JSON and halts

#### 2. PubSub broadcasts — `apps/core/lib/stacks/workers/identify_book_job.ex`
In `mark_resolved/4` (after DB update):
```elixir
Phoenix.PubSub.broadcast(Core.PubSub, "upload:#{image_id}",
  {:upload_complete, %{status: "resolved", book_ids: book_ids}})
```
In `mark_rejected/3` (after DB update):
```elixir
Phoenix.PubSub.broadcast(Core.PubSub, "upload:#{image_id}",
  {:upload_complete, %{status: "rejected", rejection_reason: reason}})
```

#### 3. Router — `apps/core/lib/core_web/router.ex`
- Add new scope using `SSEAuthPipeline`:
  ```elixir
  scope "/api", StacksWeb do
    pipe_through [:api, :sse_auth]
    get "/upload/:image_id/stream", UploadController, :stream
  end
  ```
- Remove: `get "/upload/:image_id/status", UploadController, :status`

#### 4. Controller — `apps/core/lib/stacks_web/controllers/upload_controller.ex`
Add `stream/2` action:
1. Validate `image_id` is UUID; return 400 otherwise
2. Subscribe to `Core.PubSub` topic `"upload:#{image_id}"` **before** reading DB status
3. Fetch `UploadedImage`; return 404 if missing
4. Return 403 if `image.user_id != current_user.id`
5. If status already `"resolved"` or `"rejected"`: send terminal SSE event and close
6. If `"pending"`: open chunked response with headers:
   - `Content-Type: text/event-stream`
   - `Cache-Control: no-cache`
   - `X-Accel-Buffering: no`
7. Enter receive loop: send heartbeat every 15s, close on `{:upload_complete, payload}` or after 60s timeout
8. Unsubscribe from PubSub on exit

SSE payload format (same shape as old `ProtoJSON.poll_response/1`):
```
data: {"status":"resolved","book_ids":["uuid1"],"rejection_reason":null,"is_duplicate":false}\n\n
```

Remove: `status/2`, `render_status/2`

#### 5. Tests — `apps/core/test/stacks/upload_pipeline_test.exs`
- **Remove** `describe "Suite 2 — GET /api/upload/:image_id/status"` block (lines 212–383)
- **Update** integration flows at ~lines 2087–2225 that call `/api/upload/:image_id/status`:
  - Add direct DB assertion: query `UploadedImage` and assert `status == "resolved"` / `"rejected"`
  - Add SSE stream validation: call `GET /api/upload/:image_id/stream?token=<jwt>` and assert terminal event received
- **Add** new SSE describe block covering:
  - Returns `200 text/event-stream` for valid pending image
  - Returns 401 when no token provided
  - Returns 403 when image belongs to different user
  - Returns 404 for unknown image_id
  - Sends terminal event immediately when image already resolved
  - Pushes event when `IdentifyBookJob` completes after connection opens
- **Add** `@tag :sla` test: assert `GET /api/upload/:image_id/stream` content-type response < 100ms

### Definition of Done
- [ ] `GET /api/upload/:image_id/stream` added to router under SSE auth pipeline
- [ ] JWT accepted via `?token=` query param (log-leakage documented in module comment)
- [ ] Controller streams SSE, handles already-resolved/rejected immediately
- [ ] Heartbeat sent every 15s
- [ ] `IdentifyBookJob` broadcasts on resolve AND reject
- [ ] `GET /api/upload/:image_id/status` route removed
- [ ] `UploadController.status/2` removed
- [ ] All old status endpoint tests removed
- [ ] Integration flows updated: DB assertion + SSE stream validation
- [ ] New SSE tests pass: 200, 401, 403, 404, already-resolved, push-on-complete
- [ ] `@tag :sla` test passes (< 100ms)
- [ ] `mix test` green, `mix credo --strict` clean

---

## Phase 3 — #160: Upload status via EventSource (Elm)

**Agent**: elm-agent  
**Depends on**: Phase 2 (#159) complete and merged

### Objective
Replace the 150-poll / 2-second loop in `Page.Upload` with a Server-Sent Events connection using the `GET /api/upload/:image_id/stream` endpoint.

### Scope

#### 1. Port declarations — `frontend/src/Main.elm`
Add to existing `port module Main`:
```elm
port openUploadStream : { url : String } -> Cmd msg
port uploadStreamEvent : (String -> msg) -> Sub msg
```

#### 2. JS wiring — `frontend/index.html`
```javascript
app.ports.openUploadStream.subscribe(function({ url }) {
  if (window._uploadStream) { window._uploadStream.close(); }
  const es = new EventSource(url);
  es.onmessage = function(event) {
    app.ports.uploadStreamEvent.send(event.data);
  };
  es.onerror = function() {
    app.ports.uploadStreamEvent.send(JSON.stringify({ type: "error" }));
    es.close();
  };
  window._uploadStream = es;
});
```

#### 3. JS wiring note — heartbeat guard (from contract review of #159)
The backend sends `data: {"type":"heartbeat"}\n\n` every 15s. This payload has no `status` field. The Elm `pollResponseDecoder` would map `status: ""` → `Pending` if passed the heartbeat raw JSON, causing a spurious state transition. The JS port **must** guard against this before sending to Elm:

```javascript
es.onmessage = function(event) {
  try {
    var parsed = JSON.parse(event.data);
    if (parsed.type === "heartbeat") return; // discard — no state update
  } catch (_) {}
  app.ports.uploadStreamEvent.send(event.data);
};
```

Similarly, `"timeout"` status (sent by the backend if 60s elapses with no PubSub message) must be treated as a terminal failure in the `StreamEvent` handler, not as `Pending`.

#### 4. `Page.Upload` changes — `frontend/src/Page/Upload.elm`
Remove:
- `pollCount : Int` from Model
- `maxPollCount` constant
- `sleepThenPoll` command
- `CheckStatus` Msg constructor
- `StatusReceived` Msg constructor

Add:
- `StreamEvent String` Msg constructor
- `StreamError` Msg constructor

Replace `sleepThenPoll` trigger with `openUploadStream { url = streamUrl imageId token }` in `UploadAccepted` handler, where `streamUrl` constructs `/api/upload/:image_id/stream?token=<jwt>`.

`StreamEvent` handler: decode raw string with existing `pollResponseDecoder`, route through same state transitions currently done in `StatusReceived`.

**Heartbeat guard (required — from #159 contract review):** The JS port must discard heartbeat events before sending to Elm, not pass them through to `pollResponseDecoder`. See the JS wiring note in section 3 above.

**Timeout handling (required):** The backend sends `{"status":"timeout"}` if 60s elapses. The `StreamEvent` handler must treat `status == "timeout"` as a terminal failure (same as `"rejected"` with no ISBN), not as `Pending`.

#### 4. Subscriptions — `frontend/src/Main.elm`
Add `uploadStreamEvent (UploadMsg << Upload.StreamEvent)` to subscriptions, conditional on `PageUpload` model state being active with an upload in progress.

#### 5. Remove polling — `frontend/src/Api.elm`
Remove `pollUploadStatus` function.

#### 6. Tests — `frontend/tests/UploadTest.elm`
Remove: `CheckStatus`, `StatusReceived`, `pollCount` tests.

Add:
- `StreamEvent` with resolved payload → correct model step
- `StreamEvent` with rejected payload → rejection state
- `StreamEvent` with heartbeat payload → model unchanged
- `StreamError` → appropriate error state
- Model does not contain `pollCount`

### Definition of Done
- [ ] `openUploadStream` and `uploadStreamEvent` ports declared and wired in JS
- [ ] `StreamEvent` / `StreamError` messages handle SSE data
- [ ] `sleepThenPoll`, `CheckStatus`, `StatusReceived` removed
- [ ] `Api.pollUploadStatus` removed
- [ ] `pollCount` / `maxPollCount` removed from model
- [ ] `uploadStreamEvent` subscription active only while upload in progress
- [ ] `elm-test` suite passes with new SSE tests
- [ ] `elm-format` clean
