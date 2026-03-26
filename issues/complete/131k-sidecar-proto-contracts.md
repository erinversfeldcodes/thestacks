# Issue #131k: Define Proto Contracts for Vision Sidecar + Scraper

## Summary
The vision sidecar and scraper communicate with the core API using hand-written JSON payloads with no proto contract. Define `.proto` messages for these inter-service contracts and generate typed clients/handlers.

## Goal
All inter-service communication has proto-defined contracts. The vision client (`Stacks.AI.Client`) and scraper client use proto-generated types instead of ad-hoc maps.

## Technical Requirements

### 1. Vision sidecar protos
Create `proto/stacks/internal/v1/vision.proto`:
- `ClassifyRequest` (image_b64)
- `ClassifyResponse` (classification, confidence)
- `ExtractRequest` (image_b64)
- `ExtractResponse` (books: repeated CandidateBook)
- `CandidateBook` (title, author, potential_isbns, raw_text)

### 2. Scraper protos
Create `proto/stacks/internal/v1/scraper.proto`:
- `ScrapeRequest` (url, config)
- `ScrapeResponse` (prices, availability, metadata)
- Price/availability message types matching scraper output

### 3. Generate Elixir types
Add vision and scraper messages to proto.sync or generate separate typed structs.

### 4. Wire clients
Replace hand-written map construction in `Stacks.AI.Client` with proto-typed structs:
```elixir
# Before: %{isbn: isbn, book_id: book_id}
# After: %Vision.ClassifyRequest{image_b64: image_b64}
```

### 5. Wire Python sidecar
Generate Python types from proto (already in buf.gen.yaml for Python). Wire the FastAPI endpoints to use proto-generated Pydantic models.

## Definition of Done
- [ ] Vision proto messages defined
- [ ] Scraper proto messages defined
- [ ] Elixir client uses proto types
- [ ] Python sidecar uses proto-generated types
- [ ] `buf lint` passes
- [ ] All tests pass

## Dependencies
- #131a (proto infrastructure established)

## Agent Assignment
protobuf-agent + elixir-agent + python-agent

## Progress Notes
[Updated by agents during execution.]
