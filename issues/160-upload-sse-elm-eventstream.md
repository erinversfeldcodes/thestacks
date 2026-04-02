# Issue #160: Upload status via EventSource (Elm)

## Summary
Replace the 2-second polling loop in `Page.Upload` with a Server-Sent Events connection using
the `GET /api/upload/:image_id/stream` endpoint introduced in #159. Elm has no native
`EventSource` API, so a JavaScript port pair is used. The old `Api.pollUploadStatus`,
`sleepThenPoll`, `CheckStatus`, and `StatusReceived` messages are removed.

## User Stories
US-1.1.1, US-1.1.2, US-1.1.3, US-1.1.4, US-1.1.5, US-1.1.6, US-1.1.7, US-1.1.8

## Goal
From the user's perspective: the UI transitions from "uploading…" directly to the verification
step as soon as the job completes, with no perceptible delay. Zero polling requests in the
network tab after the initial SSE connection is established.

## Technical Requirements

### 1. JavaScript ports in index.html / app.js
Add two ports:

```javascript
// outgoing: Elm asks JS to open an EventSource
app.ports.openUploadStream.subscribe(function({ url }) {
  if (window._uploadStream) {
    window._uploadStream.close();
  }
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

Port declarations in Elm:
```elm
port openUploadStream : { url : String } -> Cmd msg
port uploadStreamEvent : (String -> msg) -> Sub msg
```

### 2. Model / Msg changes in Page.Upload
Remove:
- `pollCount : Int` from Model
- `maxPollCount` constant
- `sleepThenPoll` command
- `CheckStatus` message
- `StatusReceived` message

Add:
- `StreamEvent String` message (receives raw SSE data string)
- `StreamError` message

Replace `sleepThenPoll` with a call to `openUploadStream { url = streamUrl imageId token }` where
`streamUrl` constructs `GET /api/upload/:image_id/stream?token=<jwt>`.

The JWT for the `?token=` param is already held in the model (or in session flags) — check how
the existing `Api` module passes the token to requests and use the same mechanism.

### 3. StreamEvent handler
Parse the raw JSON string from `uploadStreamEvent` using the existing `pollResponseDecoder`
(same JSON shape as the old status endpoint). Route the decoded payload through the same
`StatusReceived`-equivalent logic for `resolved` / `rejected` / heartbeat.

```elm
StreamEvent raw ->
    case Decode.decodeString pollResponseDecoder raw of
        Ok payload ->
            handleStatusPayload payload model
        Err _ ->
            ( model, Cmd.none, NoOut )
```

Heartbeat events (`{"type":"heartbeat"}`) are ignored.

### 4. Subscription
Add `uploadStreamEvent StreamEvent` to the `subscriptions` function. Remove the old
`Time.every 2000 (always CheckStatus)` subscription (or equivalent).

### 5. Remove polling code
- `Api.pollUploadStatus` function
- `maxPollCount` / `pollCount` — remove from model and init
- All poll-related `Msg` constructors

### 6. Tests
File: `frontend/tests/UploadTest.elm`
- `StreamEvent` with a resolved payload transitions model to the correct step.
- `StreamEvent` with a rejected payload sets rejection state.
- `StreamEvent` with a heartbeat payload leaves model unchanged.
- `StreamError` message sets an appropriate error state.
- Model no longer contains `pollCount`.

## Reviewer Context
- This issue depends on #159 being merged first on the shared branch.
- `pollResponseDecoder` in the `Api` module decodes the JSON shape; reuse it for SSE event
  decoding since the payload format is identical.
- Elm ports are declared with `port module` — `Page.Upload` may need to become a `port module`
  or the ports can live in `Main.elm` and be threaded down.
- The JWT is likely available in the session/flags passed to the Elm app at init; check how
  other authenticated API calls pass the token.
- `uploadStreamEvent` subscription should be conditional: only active when `uploadState` is
  `Success imageId` (i.e., an upload is in progress).

## Definition of Done
- [ ] `openUploadStream` and `uploadStreamEvent` ports declared and wired in JS
- [ ] `StreamEvent` / `StreamError` messages handle SSE data
- [ ] `sleepThenPoll`, `CheckStatus`, `StatusReceived` removed
- [ ] `Api.pollUploadStatus` removed
- [ ] `pollCount` / `maxPollCount` removed from model
- [ ] `uploadStreamEvent` subscription active only while upload in progress
- [ ] elm-test suite passes with new SSE tests
- [ ] `elm-format` clean

## Dependencies
Depends on #159 (Elixir SSE endpoint).

## Agent Assignment
elm-agent
