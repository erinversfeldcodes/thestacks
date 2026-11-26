# Vision identification request path — latency audit

Scope: the real upload → identify → stream path, read end to end. Goal is latency that
can be removed **without changing the user-facing flow**. Each finding says whether the
fix is invisible to UX or needs a flow/accuracy change (flagged out of scope).

Path, as actually wired:

```
POST /api/upload/:id/data (bytes) → commit → Oban IdentifyBookJob (queue :vision, conc 20)
  → Moderation.run_pipeline → AIClient.call_vision("analyze", …)  [HTTP → Modal FastAPI front door]
      FastAPI /analyze:  load image → [barcode tier] → [cover-text/OCR tier] → resize
                         → classify (.remote.aio → GPU)  → extract (.remote.aio → GPU)
  → ISBNResolver (OL/GB) → store → PubSub broadcast → SSE stream delivers to browser
```

Two execution surfaces matter for latency:
- the Modal **CPU front door** (`vision_api`, `scaledown_window=1200`) — warm by construction, cheap;
- the Modal **A10G GPU class** (`VisionModel`, `scaledown_window=60`, `timeout=300`) — the expensive one; a woken container bills its whole idle tail (code puts it at ~9.18c idle vs ~0.198c of inference, `modal_app.py:294-324`).

---

## Finding 1 — One identification makes TWO GPU round-trips (classify, then extract). HIGHEST VALUE.

`apps/vision/app/main.py:446` `classify_parsed = await client.classify(vlm_b64)`
`apps/vision/app/main.py:482` `extract_parsed = await client.extract([vlm_b64], …)`

`apps/vision/app/services/vision_client.py:40` and `:56` — each method is an **independent**
`model.<fn>.remote.aio(...)` dispatch against the `VisionModel` Cls. So for any image that
classifies as BOOK (the happy path), the pipeline pays **two separate Modal dispatches** to the
A10G class.

What it costs:
- **Doubled warm GPU latency on the book path.** Two full forward passes, and because each
  `.remote()` re-sends the image inside its own `messages` (`modal_app.py:485-493`), the
  **vision encoder (ViT) re-encodes the same image on both calls** — the image tokens are
  computed twice. classify only emits a ~30-token JSON, but it still pays a full image encode +
  prefill.
- **Doubled cold exposure.** The two dispatches are independent against `max_containers=10`
  (`modal_app.py:289-325`). The code itself documents that landing on two *different* containers
  is the normal case under this project's load profile — see `main.py:487-496` ("two independent
  `.remote.aio` dispatches … landing on different containers is the NORMAL case for a batch") and
  `client.ex:465-474`. So a single book can pay **two cold starts and two idle-tail scaledown
  windows** (the 60s A10G tail, the expensive line item).
- Historical note confirming the magnitude: `moderation.ex:9-16` records that the *previous*
  two-**endpoint** design (`/classify` + `/extract`) was collapsed into one `/analyze` call
  because "a second HTTP round-trip and a second cold-container start cost 2-4s of the p95." The
  HTTP hop was removed; **the two GPU dispatches were not.** The same 2-4s argument still applies
  to the GPU layer.

Fix sketch (invisible to the user-facing flow): add a single `VisionModel.analyze(image_b64)`
Modal method that runs classify and — only if the result is "book" — extract, **inside one
container, on one `.remote()` dispatch.** Same two prompts, same short-circuit semantics, but one
network round-trip, at most one cold start, one idle tail, and the extract is guaranteed to run on
the container the classify just warmed. The image can be preprocessed once and the vision encoding
reused across the two generations.

- **UX:** invisible — the browser still sees upload → single result.
- **Caveat (not a flow change, but a gate):** the classify step is a *load-bearing accuracy guard*,
  not just latency — `main.py:333-341` and the `_EXTRACT_PROMPT` comment (`modal_app.py:198-221`)
  call the classify short-circuit "the load-bearing contract for the bunny-screenshot regression,"
  i.e. it stops `extract` hallucinating books on non-book images. So the *merge into one method*
  is invisible, but if the merge also drops the separate classify generation (to save the second
  prefill) it must be scored on the whole eval corpus first. The safe, fully-invisible version
  keeps both generations and only removes the second **dispatch**.

Rank: **impact HIGH × ease MEDIUM** (needs a new Modal method + wiring; behavior-preserving).

---

## Finding 2 — The cover-text (OCR) tier runs synchronously BEFORE the GPU, and its result is thrown away in the default config. HIGH VALUE.

`apps/vision/app/main.py:394-438` runs `read_cover_text(decoded_bytes)` and measures `ocr_ms`
**before** the classify call at `:446`. It only *answers* (short-circuits the GPU) when
`settings.ocr_short_circuit` is on AND confidence clears the bar (`main.py:399-403`).

`apps/vision/app/config.py:39` `ocr_short_circuit: bool = False` — **off by default** (promotion
is a deliberate measured decision, `config.py:36-39`, and `cover_text.py:19-23` confirms it runs
"shadow by default"). So in the shipped configuration:

- Every non-barcode upload pays the **full Tesseract `image_to_data` latency** (`cover_text.py:158`)
  on the critical path, serially, *before* the GPU call…
- …and the read is then **discarded** — `answered` is `False`, the VLM runs anyway. Pure added
  latency, zero user-visible benefit, on every book identification.

Tesseract `image_to_data` over a full cover is tens-to-hundreds of ms, and it runs **inline in the
async handler** (`read_cover_text` is a sync call, not `run_in_executor` — see Finding 5), so it
also blocks the event loop.

Fix sketch (invisible): when `ocr_short_circuit` is OFF (shadow mode), the OCR read cannot change
the answer, so it must not sit on the latency path. Either (a) fire `read_cover_text` concurrently
with the classify GPU call (`asyncio.gather` / a task) and only await it for the telemetry record,
or (b) run it in a background task whose result is logged after the response. When
`ocr_short_circuit` is ON, keep it before the GPU (there it *is* allowed to answer).

- **UX:** invisible in the default (shadow) config — the answer is identical, only sooner.
- Rank: **impact MEDIUM-HIGH × ease EASY.** This is the cheapest large win: deleting wasted serial
  latency from every GPU-path identification with a one-function reorder.

---

## Finding 3 — Barcode orientation sweep: up to 6 full-resolution pyzbar decodes, serial, before anything else. MEDIUM VALUE.

`apps/vision/app/main.py:360-363` calls `local_isbn_scan(decoded_bytes)` on the **full-resolution**
decoded bytes, before OCR and the GPU.

`apps/vision/app/services/local_ocr.py:73-91`: the happy path is one decode, but on a miss it builds
5 orientation variants (mirror, 3 rotations, mirror+90) and runs `pyzbar.decode` on **each**
(`local_ocr.py:88-90`). For the common "cover photo, no barcode" case, **all 6 decodes run and all
fail**, serially, on a potentially ~10 MB image (`_MAX_DOWNLOAD_BYTES`/`max_image_size_bytes` are
both 10 MB), before the OCR tier and the two GPU calls.

Fix sketch (mostly invisible): (a) run the barcode scan against a **downscaled** copy rather than
full-res — EAN-13 bars survive moderate downscale, and the resize is needed for the VLM anyway, so
one resized buffer can feed both; or (b) parallelize the 6 variant decodes; or (c) cap the sweep.
Option (a) risks a marginal drop in barcode hit-rate on tiny/low-res barcodes, so it needs a quick
eval check — flag that slice as needing measurement, not a flow change. Parallelizing (b) is fully
invisible.

Rank: **impact MEDIUM × ease MEDIUM.** Only bites the no-barcode path (which is most uploads).

---

## Finding 4 — The same image is base64-decoded and PIL-opened up to 3× on the serial front-door path. MEDIUM VALUE.

- `apps/vision/app/main.py:352` `_load_image_b64` returns a base64 string.
- `main.py:358` `decoded_bytes = base64.b64decode(image_b64, validate=True)` — decode #1.
- `main.py:362` `local_isbn_scan(decoded_bytes)` → `local_ocr.py:73` `Image.open(...)` — PIL parse #1
  (plus up to 5 more transposes).
- `main.py:396` `read_cover_text(decoded_bytes)` → `cover_text.py:154` `Image.open(...)` — PIL parse #2.
- `main.py:442` `_resize_for_vlm(image_b64)` → `main.py:59` `base64.b64decode(...)` (decode #2) →
  `main.py:60` `Image.open(...)` — PIL parse #3, then re-encode JPEG + re-base64.

So the same JPEG is decoded from base64 twice and fully parsed by PIL three times, all serial on
the request's critical path.

Fix sketch (invisible): decode the base64 once, `Image.open().load()` once into a PIL object, and
pass that object to the barcode scan, the cover-text read, and the resize. Saves two base64 decodes
and two JPEG parses per identification.

Rank: **impact LOW-MEDIUM × ease MEDIUM.** The front door is warm CPU (cheap relative to the GPU),
but this is all pure serial latency ahead of the GPU, and the duplication is easy to remove.

---

## Finding 5 — CPU tiers (pyzbar, Tesseract) run inline in the async handler, blocking the event loop. THROUGHPUT, not single-request latency.

`main.py:362` and `main.py:396` call the sync `local_isbn_scan` / `read_cover_text` directly in the
`async def analyze` handler. The only `run_in_executor` in the service is DNS resolution
(`url_validator.py:72`); the CPU vision tiers are not offloaded.

Cost: within one request this is just the serial cost already counted above, but under the
documented concurrency (the `:vision` Oban queue runs at concurrency 20, `modal_app.py:303-307`),
several `/analyze` requests on the one warm front-door container will **serialize their CPU tiers on
the event loop**, inflating p95 under load even though each is "warm."

Fix sketch (invisible): wrap the sync CPU tiers in `await loop.run_in_executor(...)` /
`asyncio.to_thread(...)`. Naturally combines with Finding 2 (run OCR concurrently with the GPU call).

Rank: **impact MEDIUM-under-load × ease EASY.**

---

## Finding 6 — `max_new_tokens=512` is shared by classify, which needs ~30 tokens. LOW-MEDIUM VALUE.

`apps/vision/modal_app.py:508-514`: both `classify` and `extract` go through `_infer` with
`max_new_tokens=512`, greedy (`do_sample=False`). Generation is autoregressive and stops at EOS, so
the common case does not spend 512 tokens — but a classify call that fails to emit EOS pays the full
512-token generation for what is a 3-field JSON (`_CLASSIFY_PROMPT`, `modal_app.py:150-174`,
expects `{"classification","confidence","reasoning"}`).

Fix sketch (invisible): give classify its own small cap (e.g. 64) via `_infer`. Bounds the
worst-case classify latency with no effect on a well-formed response. (Mooted entirely if Finding 1
merges the calls and drops the separate classify generation.)

Rank: **impact LOW × ease EASY.**

---

## Finding 7 — Cold-start path (`@modal.enter load`) is already lean; the real cold lever is Finding 1.

`apps/vision/modal_app.py:327-434`: weights are baked into the image at build time by
`_download_model` (`modal_app.py:85-96`, `run_function` in the image plan), so `load()` reads from
local disk — no network download on cold start. The remaining cost is `AutoProcessor.from_pretrained`
+ `model_cls.from_pretrained(device_map="auto")` + the dtype/quant branch, which is the irreducible
model-load cost for a 7B VLM on an A10G. The removed `_loaded_at` timestamp and the id/counter
bookkeeping (`modal_app.py:357-375`) are O(1) and not a latency factor.

Conclusion: nothing in `@modal.enter` is cleanly trimmable or deferrable without changing the model.
The way to cut **cold-start exposure** is to stop paying it twice per identification — i.e. Finding 1.
Not an independent fix; noted so the owner doesn't chase the enter path.

Rank: **impact (as its own change) NONE × ease —.**

---

## Finding 8 — ISBN resolver: direct-ISBN path does an extra resolve for cross-checking; title search walks candidates serially. LOW VALUE (cached).

Direct-ISBN candidate (model read an ISBN): `moderation.ex:381` calls `cross_check_isbn_title` →
`moderation.ex:421` `ISBNResolver.resolve(isbn)` (an OL/GB lookup, itself **raced** in parallel —
`isbn_resolver.ex:127-131`), purely to verify the resolved title agrees with the cover title. Then
`store_book` → `resolve_metadata` → `moderation.ex:536` `Books.resolve_isbn(isbn)` resolves the
**same ISBN again**. The second lookup hits `ISBNResolverCache` (positive 24h,
`isbn_resolver.ex:99-121`), so it is effectively free — the cross-check warms the cache for the
store. Net ~1 network resolve. The cross-check itself is a correctness guard (well-formed
hallucinated ISBN, `moderation.ex:368-389`), not removable without weakening safety.

Title-search path (model read a title, no ISBN): `isbn_resolver.ex:260-268` walks up to ~12 query
variants with `Enum.reduce_while` — **serial**, OL first then GB-on-miss per variant
(`isbn_resolver.ex:277-297`) — but short-circuits on the first hit, and the whole search is cached
(`TitleSearchCache`, `isbn_resolver.ex:195-204`). Worst case (no match) is many serial HTTP calls;
typical case is one. The per-ISBN resolve (`resolve/1`) already races OL and GB in parallel (good,
`isbn_resolver.ex:127`), and multi-candidate resolution across books is already concurrent
(`moderation.ex:171-181`, `Task.async_stream` at `max_concurrency: length(expanded)`).

Fix sketch: only the title-search *worst case* is a latency lever, and it is already capped by
caching + first-hit short-circuit. Parallelizing the variant walk would help the no-match case but
risks firing many redundant upstream calls on every hit — not worth it, and borderline on OL/GB rate
limits. Leave as-is.

Rank: **impact LOW × ease LOW.** No action recommended; documented so it isn't re-investigated.

---

## SSE delivery — not a latency source (answer to the brief's question).

`upload_controller.ex:413-467` `render_stream`: on connect it reads the row once; if already
terminal (`resolved`/`rejected`) it sends immediately (`:461-463`), otherwise it subscribes to
PubSub and **waits on an event** (`sse_receive_loop`, `:499-555`) — event-driven, no polling. The
browser is unblocked by `IdentifyBookJob.mark_resolved/2`'s `Phoenix.PubSub.broadcast`
(`identify_book_job.ex:319-323`), which fires **before** the `Events.emit_safe` audit write
(`:325-330`) — correct ordering, the user-visible broadcast is not behind the event log.

Crucially, the **cheap tiers already deliver early**: a barcode hit returns from `/analyze` before
the GPU is ever called (`main.py:365-375`), and a confident cover-text answer returns before the GPU
too (`main.py:414-438`), so the whole pipeline short-circuits and the SSE broadcast happens fast.
The browser does *not* wait for the GPU when a cheap tier resolves. For a genuine VLM book it must
wait for classify + extract + resolve + store — inherent to identifying the book, and shortening
*that* is Findings 1-2, not the stream. No SSE change is needed, and streaming intermediate progress
would be a flow change (out of scope).

One trivial note: on initial connect the stream computes `is_duplicate` via
`Shelving.book_on_any_shelf?` per book (`upload_controller.ex:449`) — one DB call, negligible.

---

## Ranked summary (impact × ease)

| # | Finding | Impact | Ease | Invisible to UX? |
|---|---------|--------|------|------------------|
| 1 | Two GPU round-trips per book (classify + extract as separate `.remote.aio`) → doubled warm latency + up to 2 cold starts/idle tails | HIGH | MED | Yes if merged into one Modal method keeping both generations; dropping the classify generation needs an eval gate (not a flow change) |
| 2 | Shadow OCR tier runs serially before the GPU and is discarded in default config | MED-HIGH | EASY | Yes (shadow mode answer is identical, just sooner) |
| 3 | 6 full-res pyzbar decodes serial on every no-barcode image | MED | MED | Parallelizing: yes. Downscaling the scan input: needs a quick hit-rate check |
| 5 | CPU tiers block the async event loop (no executor offload) | MED under load | EASY | Yes |
| 4 | Same image base64-decoded 2× and PIL-parsed 3× on the serial path | LOW-MED | MED | Yes |
| 6 | `max_new_tokens=512` cap shared by the ~30-token classify | LOW | EASY | Yes |
| 8 | Extra cross-check resolve (cached) + serial title-variant walk (cached, first-hit) | LOW | LOW | n/a — no action |
| 7 | `@modal.enter` cold load already lean (weights baked) | — | — | n/a — subsumed by #1 |

Single highest-value item: **Finding 1.** It is also the one the codebase's own history already
half-solved (it collapsed the two HTTP endpoints but left the two GPU dispatches), and the one whose
cost the code explicitly quantifies (2-4s of p95, plus a second ~9c idle tail per lone cold call).
The fastest easy win is **Finding 2** (and **5**), which just moves wasted shadow-mode CPU work off
the serial GPU path.
