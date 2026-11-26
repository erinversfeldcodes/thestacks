# The shared embedding substrate — serving story

> **Status:** serving story for the one-substrate ruling (the vision cost
> architecture decision's addendum names this document as the discharge of its
> open debt; `plans/vision-accuracy-program.md` §4a holds the role analysis).
> Written 2026-11-19. The writing assistant's MODEL choice is explicitly NOT
> decided here — only the substrate both consumers share.

## What the substrate is

One pgvector install in the main Postgres, two consumer roles:

| Role | Table | Data class | Exists today |
|---|---|---|---|
| Assistant text retrieval | `op.embeddings` (vector(1024), HNSW cosine, user-FK CASCADE) | PERSONAL, user-scoped | schema + GDPR wiring since 2026-07; no producer yet |
| Cover/spine candidate generator | `op.book_visual_embeddings` (specified below) | catalogue data, book-scoped | specified here; ships WITH its writer |
| Shared corpus chunks | `op.book_content_chunks` | non-personal | schema since 2026-07 |

The point of sharing: the assistant needs pgvector regardless, so the visual
index is not net-new infrastructure — and a second GPU for the assistant is
structurally unnecessary because nothing in either role wakes a GPU at all.

## What runs where

- **Embedding compute: the vision sidecar's CPU front door.** It is the one
  always-deployed Python container, already warm for every upload (its
  scaledown is 1200s against the GPU class's 60s), already image-pinned and
  HMAC-gated. A CLIP-class image encoder (ViT-B/32, ~150MB) and a text
  embedding model run as ordinary CPU inference there — tens to low hundreds
  of ms per item, no GPU wake ever. A future `/embed` endpoint is an additive
  contract change through the same proto gate as `cpu_only` was.
- **Storage + search: Postgres.** HNSW cosine indexes; queries come from core
  (Ecto + pgvector) exactly like any other read.
- **Scoping: at QUERY time, not storage.** Cover/spine embeddings are
  book-level catalogue data (an embedding of a public cover image is no more
  personal than the cover). The "reader's own library" role is a WHERE clause:
  candidate book_ids = the reader's placements. That keeps the index one-per-
  book (not per-user copies), keeps GDPR simple (nothing user-scoped is
  added), and keeps the small-catalogue regime property — the similarity
  search runs over the ~hundreds of ids the reader owns, which is the regime
  embeddings measurably win (0.939 vs 0.783 at 15k; they LOSE at 2.3M, which
  is why the full-catalogue recognizer role stays dead).

## The visual index schema (specified; migration ships with its writer)

```sql
CREATE TABLE op.book_visual_embeddings (
  id uuid PRIMARY KEY,
  book_id uuid NOT NULL REFERENCES op.books(id) ON DELETE CASCADE,
  kind text NOT NULL,              -- 'cover' | 'spine'
  model text NOT NULL,             -- e.g. 'open_clip/ViT-B-32/laion2b_s34b_b79k'
  embedding vector(512) NOT NULL,  -- the chosen encoder's dim; a model change is a new model value + backfill
  inserted_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);
CREATE INDEX ON op.book_visual_embeddings USING hnsw (embedding vector_cosine_ops);
CREATE UNIQUE INDEX ON op.book_visual_embeddings (book_id, kind, model);
```

⚠️ **Deliberately NOT migrated yet.** A table with no writer is a zero-row
pipeline output — the "built but not wired" defect class this project hunts
with zero-row sweeps. The migration lands in the change that adds the writer
(the own-library tier), with the schema-guard run then. The recall@k
experiment does not need it: `scripts/characterise/visual-recall.py` runs
offline on the eval corpus.

GDPR at that point: book-scoped rows, no user FK — erasure untouched; the
query-time scoping reads `bookshelf_placements`, which erasure already
cascades. (The ASSISTANT's `op.embeddings` is personal and already cascades;
export summarises via the `embeddings_summary` pattern, never raw vectors.)

## Cold start and cost

- **Cold start:** the CPU front door's own (~2s FastAPI + model mmap on first
  use; the encoder can be lazy-loaded off the serial path exactly like the
  shadow OCR was). No GPU cold start exists in either role, by construction.
- **At today's scale** (~hundreds of owned books per reader, ≤60 uploads/day):
  indexing a whole library is a one-off minutes-of-CPU backfill; a query is
  one encode (~100ms CPU) + an HNSW lookup (ms). Marginal cost ≈ $0 — it rides
  containers and a database that already run. This is the "collapses most of
  its cost" claim from §4a, now stated as a serving property.
- **At 10×** (thousands of readers, ~10⁵–10⁶ embedding rows): HNSW at that
  cardinality is routine for pgvector; the encode stays per-request CPU work
  on the front door, which scales by container count with no idle-tail
  economics (CPU containers, 1200s window, already amortised across all
  traffic). The substrate's first real scaling decision (a dedicated embed
  pool, or quantised vectors) sits beyond 10× and is deliberately not
  pre-bought.

## The experiment this unblocks

`scripts/characterise/visual-recall.py` — recall@1/@5 of the own-library
candidate-generator role, offline, CPU-only: index = the cleanest corpus image
per labelled ISBN, queries = every other image of the same ISBN. It refuses to
run with an empty query set and states n per stratum (small-n honesty). Today's
corpus gives a 27-book index and 11 queries (mostly `hostile_orientation`) — a
harness-works smoke signal. **The experiment proper is gated on the owner's
spine photographs**, which add multi-image books by design; the accepted-trade
review then scores the spine stratum on both models per the cost ruling's
addendum.
