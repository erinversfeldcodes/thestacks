# Writing Assistant — Design Document

> A Socratic writing companion integrated into the blog editor. Helps users
> refine arguments, surface contradictions, and deepen their thinking — drawing
> on their reading history, shelf intent, and past writing. Encourages critical
> thinking, reading, and writing. Anti-sycophantic by design.

---

## Table of Contents

1. [Product Vision](#1-product-vision)
2. [Behaviour Model](#2-behaviour-model)
3. [System Architecture](#3-system-architecture)
4. [Model Stack](#4-model-stack)
5. [RAG Design](#5-rag-design)
6. [Chunking Strategy](#6-chunking-strategy)
7. [Hybrid Search](#7-hybrid-search)
8. [Feedback & Flywheel](#8-feedback--flywheel)
9. [Metaprompting System](#9-metaprompting-system)
10. [Insights & Drift Monitoring](#10-insights--drift-monitoring)
11. [Safety & GDPR](#11-safety--gdpr)
12. [Eval Rubric](#12-eval-rubric)
13. [Issue Breakdown](#13-issue-breakdown)

---

## 1. Product Vision

A writing assistant embedded in the blog editor — not a general-purpose chatbot,
not an autocomplete, not a ghostwriter. Its sole purpose is to make the user
think harder about what they are writing.

It operates in two modes:

- **Promptable** — user opens the panel and asks directly ("I'm not feeling
  strong about this argument")
- **Proactive** — fires a quiet notification on save or after ~90 seconds of
  writing inactivity, flagging something worth thinking about

The notification is a single pulsing dot on the assistant icon. It never
interrupts flow. The user opens it at their own pace.

The assistant knows:
- What the user has read (library bookshelf)
- What the user intends to read (wishlist, antilibrary)
- What the user has written before (past blog posts)
- What is in public domain books on their shelves (full text via Gutenberg)
- Descriptions and tables of contents for copyrighted books on their shelves

It can say: *"You've been meaning to read [Book] for six months. This post is
exactly why."* It can say: *"Your last four posts share this assumption — is it
load-bearing or a blind spot?"* It cannot write the post for the user. It cannot
suggest solutions. It asks questions.

---

## 2. Behaviour Model

### Conversation Modes

Users can select a mode to frame the dialogue:

| Mode | Bot posture |
|------|-------------|
| **Clarify** | "What exactly are you claiming?" |
| **Strengthen** | "What from your reading supports this?" |
| **Challenge** | "What in your reading contradicts this?" |
| **Expand** | "What haven't you read that would deepen this?" |
| **Synthesise** | "How does this connect to what you've written before?" |

### Anti-Sycophancy Rules (System Prompt Constraints)

These are first-class design constraints, not guidelines:

- Never lead with praise
- Never use: "great point", "interesting", "exactly", "I love that"
- Always surface the strongest objection before the strongest supporting point
- When a claim is weak, say so plainly — not "you might want to consider..."
- Ask "what would change your mind?" before generating any summary
- Reference books by name and shelf — never generically
- **Compression test:** if the argument can't survive restatement in one
  sentence, ask for restatement rather than diagnosing the problem
- Proactive nudges are one observation only — never a list
- Encourage the user to step away if the argument is unresolved
- You do not complete sentences, paragraphs, or arguments for the user
- Every book cited must come from the user's shelf data provided in context —
  never invent a title
- You have no memory between sessions except what is explicitly provided

### Proactive Nudge Triggers

- On save draft (debounced: fires at most once per 10 minutes)
- On writing pause: ~90 seconds of inactivity with unsaved changes
- Result: a single short observation (1–2 sentences), stored in the session,
  surfaced as a quiet notification dot

### Friction as a Feature

- Delay is encouraged — nudges that land after the user has stepped away are
  more valuable than ones that interrupt flow
- "Sleep on it" flag: if the bot has an unresolved observation at publish time,
  surface a non-blocking prompt: "There's something unresolved here — publish
  anyway?"
- The bot never tells the user the writing is ready

---

## 3. System Architecture

```
Elm Editor (frontend)
  └── Side panel: chat UI + notification dot
        │
        ├── POST /api/blog/posts/:id/chat        (prompted dialogue)
        └── SSE  /api/blog/posts/:id/assistant   (proactive nudge stream)
              │
              └── Stacks.AI.WritingAssistantClient (Elixir)
                    │
                    └── apps/writing_assistant/ (Python/FastAPI on Modal)
                          ├── pipeline.py   — classify → retrieve → guard → generate
                          ├── rag.py        — pgvector + FTS hybrid retrieval
                          ├── prompts.py    — loads active prompt template from DB
                          └── config.py     — Together AI client, model IDs
```

Follows the same pattern as `apps/vision/` and `Stacks.AI.Client`. The writing
assistant sidecar is a separate Modal service — different concerns, different
model stack, independent deploy.

### Session Storage

```
op.blog_assistant_sessions
  id
  post_id             FK → op.blog_posts
  user_id             FK → op.users
  turns               jsonb[]   [{role, content, nudge_type, prompt_template_id}]
  last_active_at
  inserted_at
```

One session per post. Turns accumulate as the draft evolves. Sessions older than
90 days are expired (configurable, GDPR-aligned).

---

## 4. Model Stack

All models served via Together AI. No second vendor.

| Role | Model ID | Why |
|------|----------|-----|
| Input/output safety | `meta-llama/Llama-Guard-4-12B` | Purpose-built moderation. Runs as `safety_model` param natively — no separate round-trip |
| Intent classification | `meta-llama/Meta-Llama-3-8B-Instruct-Lite` | Fast, cheap, 8k context. Classifies `in_scope / off_topic / harmful` |
| Socratic dialogue | `meta-llama/Llama-3.3-70B-Instruct-Turbo` | 131k context, strong instruction following |

### Llama Guard Integration

Together AI allows passing `safety_model: "meta-llama/Llama-Guard-4-12B"`
alongside any inference call. It filters automatically — moderation without a
separate round-trip, errors don't compound.

### Dual-Model Pipeline

```
user input
  → 8B classifier: in_scope / off_topic / harmful
      → if harmful: reject, log to audit_log
      → if off_topic: return scope boundary message
      → if in_scope:
          → RAG retrieval (pgvector + FTS)
          → 70B generation with safety_model=LlamaGuard
              → output classification pass (ghost-writing check, hallucination check)
                  → stream to client via SSE
```

### Latency Considerations

- Modal container kept warm during active editing sessions (keep-warm ping on
  session open)
- Proactive nudges use the same 70B model — nudge quality matters more than
  nudge speed
- SSE streaming means time-to-first-token is what the user perceives — optimise
  for that

---

## 5. RAG Design

### User Isolation

`user_id` is a hard filter on every similarity search. Cross-user leakage is
architecturally impossible — not just policy.

GDPR: account deletion cascades to all embeddings for that user. Right to
erasure is clean.

### Embedding Model

**`BAAI/bge-m3`** via Together AI.

- 1024 dimensions → `vector(1024)` in pgvector
- 8192 token context window — handles long book chapters and full blog posts
- Same vendor as inference — no second API key, simpler GDPR position
- Must be locked in before any content is stored — mixing embedding models in
  one vector space is invalid

### Embedding Store

```sql
op.embeddings
  id              uuid PK
  user_id         uuid FK → op.users  (indexed, never optional)
  source_type     enum: post | book_placement | book_content | chat_turn
  source_id       uuid FK to source record
  chunk_text      text
  embedding       vector(1024)
  metadata        jsonb    -- title, author, shelf_name, chapter, position, etc.
  embedding_version integer  -- increment when model or chunking strategy changes
  tsv             tsvector GENERATED ALWAYS AS (to_tsvector('english', chunk_text)) STORED
  inserted_at     timestamptz
```

```sql
CREATE INDEX embeddings_user_id_idx ON op.embeddings (user_id);
CREATE INDEX embeddings_tsv_idx ON op.embeddings USING GIN (tsv);
CREATE INDEX embeddings_vector_idx ON op.embeddings 
  USING ivfflat (embedding vector_cosine_ops);
```

### Shared Book Content (Deduplication)

Full Gutenberg text is the same regardless of user. Storing it per-user wastes
storage and GIN index overhead.

```
op.book_content_chunks       (shared, not user-scoped)
  id, book_id, chunk_text, embedding vector(1024),
  metadata jsonb, embedding_version integer, tsv tsvector, inserted_at

op.user_book_content_access  (join table)
  user_id, book_id, shelf_name, inserted_at
```

Retrieval queries join through `user_book_content_access` — isolation holds,
storage doesn't explode.

### What Gets Embedded

| Source | Trigger | Content |
|--------|---------|---------|
| Blog post | On save / publish | Post body chunks + whole-post summary chunk |
| Shelf placement | `bookshelf.placement_created` event | Title + author + shelf name |
| Shelf removal | `bookshelf.placement_removed` event | Delete embedding |
| Shelf move | Between bookshelves | Re-embed with new shelf_name in metadata |
| Book content (PD) | Placement of PD book | Full text via Gutenberg, chapter-aware |
| Book content (copyright) | Placement of any book | Description + TOC entries via Open Library |
| Chat turn | After each exchange | Turn pair (user + assistant) |

Shelf name is load-bearing metadata — antilibrary vs library signals very
different things to the retrieval and generation layers.

### Context Assembly at Generation Time

1. Retrieve top-15 chunks via hybrid search (see §7)
2. Assemble in order: most relevant at start and end, less relevant in middle
   (mitigates "lost in the middle" attention failure)
3. Pass to 70B model:
   - Current post body
   - Retrieved chunks with shelf context
   - Conversation history (last N turns, bounded by context window)
   - Active system prompt (loaded from `op.prompt_templates`)

Data minimisation: only retrieved chunks go into context, never the full shelf
dump.

---

## 6. Chunking Strategy

### Content Type 1: Blog Posts

**Characteristics:** 300–1500 words, argumentative structure, high value per
sentence.

**Strategy:**
- Split on paragraph boundaries (double newline)
- Min chunk: 50 tokens (merge short paragraphs with neighbours)
- Max chunk: 300 tokens (split long paragraphs at sentence boundary)
- 1-sentence overlap between adjacent chunks
- Additionally embed a whole-post summary chunk: first 100 + last 100 tokens
  concatenated — captures the argument arc

### Content Type 2: Public Domain Book Content (Gutenberg)

**Characteristics:** 50k–500k tokens, chapter and section structure present in
plain text.

**Strategy:**
- First pass: split on chapter/section markers
  (`CHAPTER I`, `Chapter 1`, `PART ONE`, section headers)
- Within each chapter: sliding window of 400 tokens, 50-token overlap
- Never cross chapter boundaries
- Store in metadata: `chapter_title`, `chapter_number`, `position_in_chapter`
- Non-fiction/essays: treat section headers as chapter equivalents

### Content Type 3: Copyrighted Book Metadata

**Characteristics:** Description 50–300 words; TOC is a list of chapter titles.

**Strategy:**
- Description → single chunk, no splitting
- TOC → one chunk per chapter entry (title + position number)
- TOC chunks are high-value retrieval targets — "Chapter 7: The Limits of
  Rationalism" is precise bait for an argument about rationalism

### Content Type 4: Chat Turns

**Characteristics:** 50–200 tokens, highly contextual, decays in value.

**Strategy:**
- Embed user turn + bot response together as a single chunk
- Add `post_id` and session age to metadata
- Do not embed turns older than 90 days — stale dialogue is noise

### Chunk Versioning

`embedding_version` (integer) on all embedding tables. When chunking strategy
or embedding model changes, increment the version. Re-embed in a background
worker. Old and new versions coexist during transition — retrieval filters to
`embedding_version = current`. No hard cutover, no downtime.

---

## 7. Hybrid Search

Pure cosine similarity misses exact keyword matches for author names, book
titles, and specific philosophical terms. Hybrid search combines dense
(semantic) and sparse (keyword) retrieval.

### Approach: pgvector + PostgreSQL Native FTS + RRF

No new extensions required. `tsvector` is built into every Postgres installation
and is production-stable on Neon.

**Why not pg_search / ParadeDB:** deprecated on Neon, mandatory migration
deadline June 2026. Ruled out.

**Why not pgrag:** no hybrid search support, uses smaller embedding model,
experimental status.

### Query Construction

Always use `websearch_to_tsquery` — handles arbitrary user input, multi-word
queries, punctuation, special characters. `to_tsquery` fails on multi-word
strings (known issue from CI history).

```sql
-- Dense pass (semantic similarity)
SELECT id, ROW_NUMBER() OVER (ORDER BY embedding <=> $query_embedding) AS rank
FROM op.embeddings
WHERE user_id = $user_id
  AND embedding_version = $current_version
ORDER BY embedding <=> $query_embedding
LIMIT 60;

-- Sparse pass (keyword)
SELECT id, ROW_NUMBER() OVER (ORDER BY ts_rank_cd(tsv, query) DESC) AS rank
FROM op.embeddings,
     websearch_to_tsquery('english', $query_text) AS query
WHERE user_id = $user_id
  AND embedding_version = $current_version
  AND tsv @@ query
ORDER BY ts_rank_cd(tsv, query) DESC
LIMIT 60;
```

Use `ts_rank_cd` (cover density) not `ts_rank` — more length-aware, reduces
bias toward longer chunks.

### RRF Merge (in Elixir)

```elixir
# Reciprocal Rank Fusion, k=60
score = 1 / (60 + dense_rank) + 1 / (60 + sparse_rank)
```

Take top 15 after merge. Pass all 15 to the model — let the 70B model
implicitly re-rank by attention (no cross-encoder reranker available on Together
AI serverless).

### Third Pass: Structured Metadata Exact Match

Author names and book titles are poor candidates for both cosine similarity and
FTS tokenisation. Run a separate exact-match query on the `metadata` JSONB
column and merge results into the RRF pool:

```sql
SELECT id, 1 AS rank  -- exact match, always promoted
FROM op.embeddings
WHERE user_id = $user_id
  AND (
    metadata->>'author' ILIKE $extracted_entity
    OR metadata->>'title' ILIKE $extracted_entity
  )
```

### Known Weaknesses

| Weakness | Mitigation |
|----------|-----------|
| `ts_rank_cd` is not true BM25 — approximate IDF | Acceptable for v1; revisit if retrieval quality proves poor |
| RRF constant (60) is untuned | Log retrieval usage; tune via insights loop |
| No cross-encoder re-ranker | Return top-15 to model; add dedicated re-ranking if metrics warrant |
| Author name tokenisation | Structured metadata exact-match third pass |
| Query parsing edge cases | `websearch_to_tsquery` everywhere |

---

## 8. Feedback & Flywheel

### Design Principle

**Do not build a system that learns to please users.**

Feedback must capture *usefulness* not *enjoyment*. Sycophantic responses feel
good in the moment — users would thumb them up. We would be training toward
responses that feel validating, not responses that sharpen thinking.

### Asymmetric Signal Design

**Explicit:** thumbs down only. No thumbs up button visible.
**Implicit:** derived from behaviour, not prompted.

A turn is positively signalled if:
- No explicit thumbs down
- Session continued (user sent ≥1 more message)
- User edited the post within 2 hours of the turn

### Feedback UI

**Chat turns:**
- Small thumbs down icon, appears on hover on bot turns only
- Single confirmation on click: "Mark as unhelpful?" — prevents accidental taps
- No comment field — friction kills response rate

**Proactive nudges:**
- "Not relevant" dismiss button on the notification
- Opening the panel = implicit positive signal
- Never opened within 24 hours = `nudge_ignored` (set by async worker)

**What we do not build:**
- Star ratings
- "Was this helpful? Yes / No" prompts
- End-of-session surveys
- Any mechanism that asks users to evaluate quality while in flow

### Schema

```sql
op.turn_feedback
  id              uuid PK
  session_id      uuid FK → op.blog_assistant_sessions
  turn_index      integer
  signal          enum:
                    negative_explicit   -- thumbs down
                    nudge_dismissed     -- "not relevant"
                    nudge_ignored       -- nudge fired, panel never opened (async)
                    session_abandoned   -- <2 turns, no edit after
  prompt_template_id  uuid FK → op.prompt_templates
  retrieval_ids   uuid[]  -- which chunks were retrieved for this turn
  inserted_at     timestamptz
```

Derived positive signal lives in a materialised view, not the table:

```sql
-- op.turn_positive_signals (materialised, refreshed hourly)
SELECT s.id AS session_id, t.turn_index, t.prompt_template_id, true AS positive
FROM blog_assistant_sessions s
JOIN session_turns t ON t.session_id = s.id
WHERE t.role = 'assistant'
  AND NOT EXISTS (
    SELECT 1 FROM turn_feedback f
    WHERE f.session_id = s.id
      AND f.turn_index = t.turn_index
      AND f.signal = 'negative_explicit'
  )
  AND s.turn_count > 2
  AND EXISTS (
    SELECT 1 FROM blog_posts p
    WHERE p.id = s.post_id
      AND p.updated_at > t.inserted_at
      AND p.updated_at < t.inserted_at + interval '2 hours'
  )
```

### The Three Flywheel Loops

**Loop 1: Prompt refinement (days/weeks)**
```
prompt version activated
→ sessions accumulate with prompt_template_id
→ insights dashboard: negative feedback rate, abandonment rate,
  turn depth, nudge open rate
→ write new prompt version, test against golden eval set
→ activate — all new sessions pick it up instantly, no deploy
```

**Loop 2: Retrieval quality (weeks/months)**
```
retrieval_log accumulates
→ measure: retrieved chunks never used in generation
→ identify: content types with low utilisation
→ adjust: RRF weights, chunk size, top-K
→ re-embed if chunking strategy changes (increment embedding_version)
```

**Loop 3: Fine-tuning (months)**
```
enough negative feedback accumulates
→ identify: what do thumbs-down turns have in common?
→ build fine-tuning dataset:
    positive: sessions with turn_count > 4, no negative signals, post edited
    negative: sessions with explicit negatives or abandoned after 1 turn
→ fine-tune smaller model on Socratic dialogue behaviour
→ potentially replace 70B with a fine-tuned 13B
```

### Cold Start

Before feedback accumulates:
1. **Synthetic eval set** (golden conversations from §12) acts as feedback proxy
2. **Implicit signals first** — nudge open rate and session depth are available
   from day one

---

## 9. Metaprompting System

Prompts live in the database, not in code. Edit, version, and A/B test without
a deploy.

### Schema

```sql
op.prompt_templates
  id              uuid PK
  name            text           -- e.g. "system_socratic", "classification_intent"
  role            enum: system | classification | summary
  version         integer        -- auto-increment per name
  content         text
  model_id        text           -- Together AI model ID
  active          boolean
  inserted_at     timestamptz

op.prompt_experiments
  id              uuid PK
  template_id     uuid FK → op.prompt_templates
  variant_name    text
  traffic_split   float          -- 0.0–1.0
  started_at      timestamptz
  ended_at        timestamptz    -- null = running
```

Each session turn records `prompt_template_id`. Every conversation is traceable
to the exact prompt version that generated it.

Activating a new prompt version → all new sessions use it instantly.

### Eval Runner

Before activating a new prompt version, run it against the golden eval set
(§12). Score each turn against the rubric dimensions. Compare against the
currently active version. Promote only if scores are equal or better across all
dimensions.

This runs in the admin panel — no CLI, no deploy required.

---

## 10. Insights & Drift Monitoring

### Retrieval Log

```sql
op.retrieval_log
  id              uuid PK
  session_id      uuid FK
  turn_index      integer
  chunk_ids       uuid[]     -- retrieved
  chunk_scores    float[]    -- RRF scores at retrieval time
  chunks_used     uuid[]     -- appeared in generation (inferred)
  query_embedding vector(1024)  -- for drift detection
  inserted_at     timestamptz
```

### Metrics Per Prompt Version

| Metric | What it tells you |
|--------|------------------|
| Session depth (avg turns) | Is dialogue substantive or abandoned? |
| Proactive nudge open rate | Are notifications useful or ignored? |
| Mode distribution | Which modes users actually reach for |
| Flag rate (input + output) | Is safety layer over/under-triggering? |
| Post edit rate after session | Did the bot change the writing? |
| Time between nudge and publish | Are users slowing down to think? |
| Negative explicit rate | Direct quality signal per prompt version |

### Retrieval Health Materialised View

```sql
-- op.retrieval_health (materialised, refreshed daily)
SELECT
  date_trunc('week', inserted_at)          AS week,
  avg(cardinality(chunks_used)::float /
      cardinality(chunk_ids)::float)        AS utilisation_rate,
  avg(chunk_scores[1])                     AS avg_top_score,
  count(*) FILTER (WHERE cardinality(chunks_used) = 0) AS zero_utilisation_turns
FROM op.retrieval_log
GROUP BY 1
```

**Alert conditions:**
- `utilisation_rate` drops below 0.3 → retrieval is returning irrelevant content
- `zero_utilisation_turns` spikes → corpus drifting from what users write about
- `avg_top_score` drops → embedding space may be degrading

Alerts route through existing Oban + event infrastructure.

### Drift Detection

What drifts:
- **Query drift** — users write about topics not in the book corpus
- **Retrieval drift** — previously-used chunks now rarely retrieved (topic moved on)
- **Embedding drift** — if embedding model ever changes, old vectors are in a
  different space (mitigated by `embedding_version`)

`query_embedding` stored in `retrieval_log` enables offline clustering analysis:
are recent queries drifting away from the centroid of the embedded corpus?

---

## 11. Safety & GDPR

### Input Sanitization

- **Intent classification** — 8B pre-pass classifies `in_scope / off_topic /
  harmful` before routing to 70B
- **Scope enforcement** — input must relate to the current post body or a shelf
  book; otherwise rejected with a plain boundary message
- **Hard blocklist** — keyword/pattern check for obvious harmful content; flagged
  attempts logged to `audit_log` (flag + timestamp + user_id, not content)
- **Length cap** — inputs over N tokens rejected; prevents prompt injection via
  padding
- **Injection stripping** — user input containing `<system>`, `ignore previous
  instructions`, or similar patterns is rejected before reaching the model

### Output Sanitization

- **Post-generation classification** — same lightweight pass on output
- **Ghost-writing detection** — if output contains >2 contiguous prose sentences
  (rather than questions or observations), discard and return fallback
- **Hallucination grounding** — any book cited must exist in the retrieved chunk
  set for that turn; validated before returning response
- **Self-harm / crisis content** — output screened; if triggered, discard
  entirely and return a static human-written message pointing to appropriate
  resources. No generated response, no exceptions

### System Prompt Behavioural Constraints

(See §2 Anti-Sycophancy Rules — these are enforced in the system prompt as well
as in the output sanitization layer.)

### GDPR

- **Data minimisation** — only current post body + retrieved chunks in context;
  full shelf never dumped into prompt
- **No training on user data** — Together AI API with training disabled
  (Anthropic-style: default for API customers, explicitly configured and
  documented)
- **Retention** — sessions and embeddings subject to 90-day retention or
  user-configurable; deletable independently of account
- **Right to erasure** — account deletion cascades to sessions + embeddings +
  retrieval_log. Documented in privacy policy as a specific AI feature
- **Audit log** — flagged inputs logged (flag type + timestamp + user_id, never
  content)
- **Transparency** — user-facing copy: "This assistant uses your shelf and
  writing history to personalise suggestions. It does not store your data beyond
  your session history. [Manage your data]"
- **No cross-user inference** — embeddings are never used to train shared models,
  cluster users, or derive aggregate insights. Personal RAG only. Documented in
  internal architecture docs

### Crisis Response

A static, human-written response is returned if the safety classifier detects
self-harm content in either input or output. It is never generated by the model.
It points to appropriate resources. It is reviewed and approved before deploy.

---

## 12. Eval Rubric

Each bot turn is scored on six dimensions. This rubric drives:
1. The golden eval set (20–30 hand-rated example conversations)
2. Automated eval before activating a new prompt version
3. The few-shot examples embedded in the system prompt

### Turn-Level Rubric

| Dimension | Bad | Good |
|-----------|-----|------|
| **Grounding** | "You might enjoy Seneca's Letters" (not on shelf) | "Seneca's *Letters* is in your antilibrary — it addresses this directly" |
| **No praise** | "Great point — building on that..." | "This claim rests on an assumption you haven't examined:" |
| **Question over verdict** | "Your argument is weak here" | "What evidence would change your position on this?" |
| **Specificity** | "You might want to think about counterarguments" | "Your second paragraph asserts X without addressing Y — what's your basis?" |
| **Scope adherence** | "Have you tried journalling instead?" | "There's a structural tension between your opening claim and your conclusion" |
| **Compression test** | "This argument has several problems: first..." | "Can you state your core claim in one sentence?" |

### Proactive Nudge Rubric (additional)

| Dimension | Bad | Good |
|-----------|-----|------|
| **One observation only** | "I noticed three things..." | "Your opening claim contradicts your conclusion — worth resolving before publishing" |
| **Tone** | "Looks good! One small thing..." | "There's something here worth thinking about when you're ready" |

### Scoring

Each dimension is binary (pass/fail) for automated eval. A turn must pass all
six dimensions. Prompt versions that regress on any dimension are not activated.

---

## 13. Issue Breakdown

| Issue | Scope | Dependencies |
|-------|-------|-------------|
| **A** | pgvector + `op.embeddings` migration + `op.book_content_chunks` + shelf/post embedding Oban workers | None |
| **B** | RAG retrieval layer — hybrid search (pgvector + FTS + RRF), user-scoped queries, metadata exact-match pass, `embedding_version` | A |
| **C** | `apps/writing_assistant/` Modal service — pipeline, Together AI integration, Llama Guard wiring, chunking workers | A, B |
| **D** | Prompt templates + experiments schema + `Stacks.AI.WritingAssistantClient` + metaprompting admin | None |
| **E** | Chat endpoint `POST /api/blog/posts/:id/chat` + SSE streaming + `blog_assistant_sessions` schema | C, D |
| **F** | Proactive analysis Oban worker — save/idle triggers, nudge generation, debounce | C, D, E |
| **G** | Book content ingestion — Gutenberg PD detection + fetch + chapter-aware chunking + Open Library TOC | A |
| **H1** | Insights schema — `op.retrieval_log`, `op.turn_feedback`, `op.turn_positive_signals` materialised view, drift alert worker | E |
| **H2** | Insights dashboard + eval runner admin page + prompt cohort comparison | D, H1 |
| **I** | Elm UI — side panel, chat interface, notification dot, mode selector, thumbs down, nudge dismiss | E, F |

**Critical path:** A → B → C → E → F → I

**Can parallelise after A:** G (book ingestion), D (prompt system), H1 (insights schema)
