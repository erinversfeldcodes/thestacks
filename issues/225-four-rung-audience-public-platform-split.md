# Issue #225: Real 4-rung Audience — settable `public` + auth-gated `platform`

## Summary
Make the Audience ladder fully real and correctly enforced. Today the ladder is
`owner < group < platform` and `platform` is served to **everyone including
unauthenticated** visitors; `public` is reserved and unstorable. This issue lands
the product-intended model:

| Rung | Meaning | Who can read |
|------|---------|--------------|
| `owner` | only me (**default — already the DB default**) | owner only |
| `group` | a chosen group ("friends") | owner + group members — **deferred to #224** |
| `platform` = **"Members"** | any **signed-in** user | authenticated only (**anon → hidden**) |
| `public` | **anyone with the link** | everyone incl. unauthenticated |

`public` is **anon-readable but stays `noindex`** — the app remains globally
robots-disallowed / non-crawlable. Search-engine indexing is a separate future
opt-in, explicitly out of scope here.

This un-defers the "public rung" + "platform auth-gate" that #209 listed as
GENUINELY FUTURE, now that the semantics are locked.

## Behaviour change (important)
This **flips the just-shipped public-profile feature** for logged-out visitors:
- Before: an anonymous visitor could read a `platform` profile/shelf.
- After: an anonymous visitor reads only `public` ones; a `platform` profile is
  Members-only (anon → 404). To be anon-visible, a user sets `public`.

Existing `platform` rows are unchanged in storage; their *effective* audience
narrows from "anyone" to "signed-in". That is the intended tightening (users who
picked "Members" expecting signed-in-only now get exactly that).

## Scope
1. **Migration** — `ALTER TYPE op.visibility_level ADD VALUE 'public'` (after
   `platform`; one-way, `@disable_ddl_transaction`).
2. **Proto** — un-reserve `AUDIENCE_PUBLIC = 4` in `visibility.proto`; regenerate.
3. **Vocabulary** — `@audience_levels ~w(owner group platform public)`;
   `@profile_audience_levels ~w(owner platform public)` (group deferred to #224).
   Shelving's `@valid_visibilities` single-sources from `audience_levels/0` already.
4. **Resolver enforcement** (`Stacks.Visibility`):
   - `check_resource_visibility`: `{"public", _} → :ok`;
     `{"platform", {:platform_user,_}}`/`:platform_preview → :ok`;
     `{"platform", :unauthenticated} → :hidden`.
   - `check_profile_ceiling`: a `platform` profile is a ceiling for anon
     (`{"platform", :unauthenticated} → :hidden`) so a public shelf under a
     Members-only profile is not leaked to logged-out visitors.
   - `profile_visible?`: `:unauthenticated` sees only `pv == "public"`;
     signed-in sees `platform`/`public` (owner/group gated as today / #224).
5. **Elm/UI** — `Types.Visibility` → `Owner | Group | Platform | Public` with
   exposure-ordered `rank` (owner 0 < group 1 < platform 2 < public 3); honest
   labels ("Only me" / "Group" / "Members" / "Anyone with the link"); offer
   `public` in the shelf + profile visibility controls (Settings/Privacy) and the
   per-placement dropdown (owner/platform/public — group omitted per the owner's
   call); fix the stale `@visibility_rank` docstring.
6. **Warehouse** — `sources.yml` visibility docs gain `public`; regenerate dbt.
7. **Tests** — resolver (platform hides anon, public shows anon), profile_controller
   (anon → public not platform), `public-profile.spec.ts` (anon sees a `public`
   profile; a `platform` profile is 404 to anon), Elm + the proto drift test.

## Definition of Done
- [ ] Migration adds `public`; `just verify` migrates a fresh DB cleanly.
- [ ] Resolver: platform is signed-in-only; public is anyone (incl. anon); parity
      for owner/group unchanged. Property + unit suites green.
- [ ] Public-profile feature updated for the anon flip; E2E asserts the new matrix.
- [ ] Elm 4-rung ladder + honest labels; `public` settable in the UI.
- [ ] `noindex` unchanged (public is anon-readable, not crawlable).
- [ ] `just run just verify` green; drift test (proto ↔ Elixir) green.

## Dependencies
Builds on #209 Phase 1 (the `Audience` proto + single-sourced vocabulary).
`group` profile ceiling remains #224. GDPR: `public` widens read audience — confirm
the export/erasure paths are unaffected (they operate per-owner, not per-audience).

## Source
Owner product decision during the #209 Phase 1/3b discussion (2026-07-15).
