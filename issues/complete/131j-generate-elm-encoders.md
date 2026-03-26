# Issue #131j: Generate Elm Encoders from Proto for Request Bodies

## Summary
Replace hand-written `Encode.object` calls in `Api.elm` with proto-generated Elm encoders. Currently all POST/PUT request bodies are hand-built — adding a field to a request requires manually updating `Api.elm`.

## Goal
Request body construction in `Api.elm` delegates to proto-generated encoders, same as response decoding delegates to proto-generated decoders.

## Technical Requirements

### 1. Define request proto messages
Some request shapes don't have proto definitions yet. Create messages for:
- `LoginRequest` (email, password)
- `RegisterRequest` (email, password, display_name)
- `PlaceBookRequest` (book_id)
- `MoveBookRequest` (bookshelf)
- `UpdateProfileRequest` (display_name, email, website_url, current_password)
- `UpdateLocationRequest` (country_code, city)
- `UpdateNotificationsRequest` (notify_* fields)
- `ChangePasswordRequest` (current_password, new_password)
- `CreateListingRequest` (book_id, condition, pricing_mode, price_zar, description, contact_info)
- `CreateBlogPostRequest` (title, body, visibility)
- `MergeFormatRequest` (isbn, format_label)
- etc.

Add these to `proto/stacks/api/v1/requests.proto` (new file).

### 2. Generate Elm encoders
The gen-elm-proto.py already generates encoders (`encode<TypeName>`). The generated encoders need to be wired into `Api.elm`.

### 3. Wire Api.elm
Replace:
```elm
body = Http.jsonBody (Encode.object [ ( "email", Encode.string body.email ), ... ])
```
With:
```elm
body = Http.jsonBody (ProtoRequests.encodeLoginRequest { email = body.email, ... })
```

### 4. Adapter pattern (if needed)
If the proto request type has different field names from what the app uses, create thin adapter encoders (same pattern as decoder adapters in Types/*.elm).

## Definition of Done
- [ ] Request proto messages defined for all API endpoints
- [ ] Elm encoders generated from proto
- [ ] `Api.elm` uses generated encoders for all POST/PUT bodies
- [ ] All tests pass
- [ ] All E2E tests pass

## Dependencies
- #131b (Elm generator already produces encoders)
- #131f (adapter pattern established)

## Agent Assignment
elm-agent + protobuf-agent

## Progress Notes
[Updated by agents during execution.]
