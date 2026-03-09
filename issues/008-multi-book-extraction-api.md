# Issue #008: Multi-Book Extraction API — Amends Issue #003

## Summary
Amend the Python vision sidecar (Issue #003) to support extracting multiple books from a single image and to correctly classify screenshot inputs. These are breaking API changes that must land before the bulk upload flow (Issue #009) can be implemented.

## Problem

The current sidecar has two limitations that block bulk upload and real-world input diversity:

1. **`/extract` returns a single book.** The `ExtractionResponse` model has flat fields (`title`, `author`, `potential_isbns`). A screenshot of a reading list or a shelfie photo may contain multiple identifiable books. The sidecar silently discards all but the most prominent one.

2. **`/classify` prompt assumes a physical book photo.** The current prompt asks "Is it a book?" — a screenshot of a tweet recommending a novel is not a photo of a book, so the model may return `not_book` and the image gets rejected before extraction is attempted. The correct question is: "Does this image contain enough information to identify a book?"

## Changes

### 1. `/extract` — response format (breaking change)

**Before:**
```json
{
  "title": "Dune",
  "author": "Frank Herbert",
  "potential_isbns": ["9780441013593"],
  "raw_text": "Dune Frank Herbert",
  "model_used": "Qwen/Qwen2.5-VL-7B-Instruct",
  "confidence": 0.0
}
```

**After:**
```json
{
  "books": [
    {
      "title": "Dune",
      "author": "Frank Herbert",
      "potential_isbns": ["9780441013593"],
      "raw_text": "Dune Frank Herbert",
      "confidence": 0.0
    },
    {
      "title": "The Left Hand of Darkness",
      "author": "Ursula K. Le Guin",
      "potential_isbns": [],
      "raw_text": "The Left Hand of Darkness Ursula K. Le Guin",
      "confidence": 0.0
    }
  ],
  "model_used": "Qwen/Qwen2.5-VL-7B-Instruct"
}
```

`books` is always a list. Single-book images return a list of one. If nothing is extractable, return an empty list (not an error).

**New Pydantic models:**
```python
class ExtractedBook(BaseModel):
    title: str | None = None
    author: str | None = None
    potential_isbns: list[str] = Field(default_factory=list)
    raw_text: str | None = None
    confidence: float = Field(ge=0.0, le=1.0, default=0.0)

class ExtractionResponse(BaseModel):
    books: list[ExtractedBook]
    model_used: str
```

### 2. `/extract` — prompt update

The extraction prompt must instruct the model to return all identifiable books, not just the most prominent one:

```
Extract all books visible or mentioned in this image. For each book, return its title,
author name, and any ISBN numbers visible. If the image is a screenshot of text
(social media post, article, reading list), extract all books mentioned in the text.
Return JSON with field: books (array of objects, each with: title, author,
potential_isbns (array of strings), raw_text).
If no books can be identified, return {"books": []}.
```

This prompt replaces the current single-book extraction prompt in `_EXTRACT_SYSTEM_PROMPT`.

### 3. `/classify` — prompt update

The classification prompt must correctly handle screenshot inputs:

```
Does this image contain enough information to identify a book?

Answer "book" if: the image shows a physical book (cover, spine, back, or barcode),
OR the image is a screenshot or photo of text that mentions a specific book title or author.

Answer "not_book" if: the image has no book-related content whatsoever (a pet, food,
a landscape, a selfie with no book context).

Answer "ambiguous" if: there is some possible book-related content but not enough
to attempt identification.

Return JSON: {"classification": "book" | "not_book" | "ambiguous", "confidence": 0.0-1.0}
```

### 4. Elixir `Stacks.AI.Client` — consume new response format

`Stacks.AI.Client.extract_book/2` currently pattern-matches on a flat response. It must be updated to handle `%{"books" => [...]}`.

For the interim single-image flow (before Issue #009), the client takes the first element of the list:
- If `books` is empty → `{:error, :no_extraction}`
- If `books` has one or more elements → use `books[0]` as the primary candidate, proceed through existing ISBN resolution pipeline

`books[1..]` are preserved in the response but not acted on until Issue #009 (bulk upload orchestration). The Oban `IdentifyBookJob` does not need to change yet — it processes one candidate per job.

**Files to update:**
- `apps/vision/app/models/extraction.py` — new `ExtractedBook` model, updated `ExtractionResponse`
- `apps/vision/app/services/vision_client.py` — updated `_EXTRACT_SYSTEM_PROMPT`, updated `_CLASSIFY_SYSTEM_PROMPT`
- `apps/vision/app/main.py` — `/extract` endpoint builds `ExtractionResponse(books=[...])`
- `apps/vision/tests/test_extraction.py` — all tests updated for new response shape
- `apps/vision/tests/test_vision_client.py` — updated mock responses
- `apps/vision/tests/fuzz_image_input.py` — updated mock responses
- `apps/core/lib/stacks/ai/client.ex` — updated response parsing
- `apps/core/test/stacks/ai/client_test.exs` — updated fixtures

## Definition of Done

- [ ] `ExtractedBook` Pydantic model defined; `ExtractionResponse.books` is `list[ExtractedBook]`
- [ ] `/extract` returns `books: []` (not an error) when nothing is extractable
- [ ] `/extract` returns multiple entries in `books` when the model identifies more than one book
- [ ] Updated extract prompt instructs the model to extract all books, including from screenshot text
- [ ] Updated classify prompt correctly accepts screenshot inputs as `book` rather than rejecting them
- [ ] Elixir `Stacks.AI.Client` handles `books: []` → `{:error, :no_extraction}` and `books: [head | _]` → existing pipeline with `head`
- [ ] All existing Python tests pass with updated response shape
- [ ] New Python tests cover: multi-book response (2+ entries), empty books list, screenshot input classified as `book`
- [ ] `ruff check`, `ruff format --check`, `mypy --strict` pass
- [ ] `mix test` passes (Elixir client tests updated)

## Dependencies
- Issue #003 complete (vision sidecar implemented)

## Blocks
- Issue #009 (bulk upload) — the bulk upload orchestration depends on the multi-book list response

## Sequencing note
Issue #007 (local OCR pre-pass) is independent of this issue — both amend the sidecar but touch different parts. They can be implemented in either order or in parallel. If both are in flight simultaneously, coordinate on `app/main.py` and `app/models/extraction.py` to avoid conflicts.

## Agent Assignment
- **python-agent** for sidecar changes
- **elixir-agent** for `Stacks.AI.Client` update
- **Reviewer**: python-reviewer + elixir-reviewer
- **Model**: Sonnet 4.6

## Progress Notes
<!-- Updated by agents during execution -->
