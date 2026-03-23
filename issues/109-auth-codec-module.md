# Issue #109: Elm AuthCodec Module

## Summary
Create a single Elm module responsible for User construction, encoding, and decoding to prevent field drift across the auth pipeline.

## Goal
Currently the User record is constructed in 4+ locations (decodeFlags, login handler, registration handler, Profile.init fallback) and encoded/decoded in 2 locations (encodeAuth, decodeFlags). Adding a field (like `role`, `countryCode`, `city`) requires updating all locations — missing one silently breaks features. A single AuthCodec module eliminates this.

## Scope Check
- 1 new Elm module
- Modify Main.elm to use it
- ~100 LOC

## Technical Requirements

### AuthCodec module
Create `src/AuthCodec.elm`:
```elm
module AuthCodec exposing (encodeAuth, decodeAuth, emptyUser, userFromAuthResponse)

encodeAuth : Auth -> Json.Encode.Value
decodeAuth : Decode.Value -> Maybe Auth
emptyUser : User
userFromAuthResponse : AuthResponse -> User
```

- `encodeAuth` — single location for serialising auth to localStorage
- `decodeAuth` — single location for deserialising from flags
- `emptyUser` — default user record with all fields (used by Profile.init fallback)
- `userFromAuthResponse` — constructs User from login/register API response

### Migrate Main.elm
- Replace inline `Decode.map5 ...` in `decodeFlags` with `AuthCodec.decodeAuth`
- Replace inline `Json.Encode.object [...]` in `encodeAuth` with `AuthCodec.encodeAuth`
- Replace inline `{ id = ar.userId, ... }` in login handlers with `AuthCodec.userFromAuthResponse`
- Replace inline `{ id = "", ... }` fallbacks with `AuthCodec.emptyUser`

## Definition of Done
- [ ] All User construction goes through AuthCodec
- [ ] Adding a field to User requires changing only AuthCodec + Types.User
- [ ] All tests pass
- [ ] `elm-review` clean

## Agent Assignment
elm-agent
