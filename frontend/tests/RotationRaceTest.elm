module RotationRaceTest exposing (suite)

{-| Tests for Phase 2 — cross-tab token propagation + re-check-before-
logout net.


## What this covers

Backend Phase 1 added a rotation grace so an in-flight just-rotated token no
longer burns the refresh-token family. Phase 2 stops the _multi-tab_ spurious
logout: when tab A renews (rotates `T0 -> T1`, writing localStorage `stacks-auth`)
while tab B still holds `T0` in memory, tab B must ADOPT `T1` rather than logging
every tab out on its next 401.

The decision is centralised in one PURE, key-free helper — `Main.adoptExternalAuth`
— so it is unit-testable even though `Main` itself is a `Browser.application`
(unconstructable `Nav.Key`; see `SessionExpiryTest`'s seam note). The same helper
backs BOTH:

  - the cross-tab `storage`-event path (`AuthChangedExternally`), and
  - the 401 re-check-before-logout net (`GotStoredAuth`).

The Main-level wiring (ports, subscriptions, redirect) is E2E-covered by
`e2e/tests/rotation-race.spec.ts`.

-}

import Expect
import Json.Encode as Encode
import Main
import Test exposing (Test, describe, test)
import Types.User exposing (User)


suite : Test
suite =
    describe "Cross-tab token propagation + re-check net"
        [ describe "adoptExternalAuth — cross-tab storage propagation"
            [ differentTokenWhileAuthedAdopts
            , differentTokenPreservesUser
            , sameTokenIsIgnored
            , clearedWhileAuthedLogsOut
            , clearedWhileSignedOutIsIgnored
            , garbageStringIsIgnored
            , garbageNonStringIsIgnored
            , validAuthWhileSignedOutIsIgnored
            ]
        , describe "adoptExternalAuth — reused for the 401 re-check net"
            [ recheckNewerStoredTokenAdopts
            , recheckSameStoredTokenProceedsToLogout
            ]
        , describe "resolveRecheck — origin-aware reschedule + parked-intent handling"
            [ renewalOriginAdoptReschedules
            , pageOriginAdoptDoesNotReschedule
            , recheckSameTokenForcesLogoutCarryingDraft
            , recheckClearedForcesLogout
            , noParkedIntentIsNoop
            , interleaveExternalAdoptCancelsParkedLogout
            ]
        , describe "parkPending — P2 sticky draft/renewal flags across overlapping expiry"
            [ plainExpiryDoesNotDowngradeDraftSaved
            , draftExpirySetsDraftSaved
            , renewalAndDraftOriginsMerge
            ]
        ]


aReader : User
aReader =
    { id = "user-1"
    , email = "reader@stacks.dev"
    , displayName = "A Reader"
    , handle = "a_reader"
    , role = "user"
    , countryCode = Nothing
    , city = Nothing
    , consentAnalytics = False
    , consentWritingAssistant = False
    }


authWith : String -> Main.Auth
authWith token =
    { user = aReader, token = token }


{-| Build the raw localStorage string a sibling tab wrote (the exact shape
`Main.encodeAuth` produces), delivered through the port as a JSON string Value —
mirroring how the browser hands `storageEvent.newValue` (a string) to the port.
-}
storedAuthValue : String -> Encode.Value
storedAuthValue token =
    Encode.string
        (Encode.encode 0
            (Encode.object
                [ ( "token", Encode.string token )
                , ( "userId", Encode.string aReader.id )
                , ( "email", Encode.string aReader.email )
                , ( "displayName", Encode.string aReader.displayName )
                , ( "handle", Encode.string aReader.handle )
                , ( "role", Encode.string aReader.role )
                ]
            )
        )


differentTokenWhileAuthedAdopts : Test
differentTokenWhileAuthedAdopts =
    test "different_token_while_authed_adopts: a sibling tab's newer token is adopted" <|
        \() ->
            Main.adoptExternalAuth (storedAuthValue "T1") (Just (authWith "T0"))
                |> Expect.equal (Main.AdoptAuth (authWith "T1"))


differentTokenPreservesUser : Test
differentTokenPreservesUser =
    test "different_token_preserves_user: adoption swaps the token but keeps the same user" <|
        \() ->
            case Main.adoptExternalAuth (storedAuthValue "T1") (Just (authWith "T0")) of
                Main.AdoptAuth adopted ->
                    Expect.all
                        [ \a -> a.token |> Expect.equal "T1"
                        , \a -> a.user |> Expect.equal aReader
                        ]
                        adopted

                _ ->
                    Expect.fail "expected AdoptAuth for a different token while authed"


sameTokenIsIgnored : Test
sameTokenIsIgnored =
    test "same_token_is_ignored: a storage write echoing the in-memory token is a no-op" <|
        \() ->
            Main.adoptExternalAuth (storedAuthValue "T0") (Just (authWith "T0"))
                |> Expect.equal Main.IgnoreExternal


clearedWhileAuthedLogsOut : Test
clearedWhileAuthedLogsOut =
    test "cleared_while_authed_logs_out: a sibling clearAuth (null) logs this tab out" <|
        \() ->
            Main.adoptExternalAuth Encode.null (Just (authWith "T0"))
                |> Expect.equal Main.LogOutExternally


clearedWhileSignedOutIsIgnored : Test
clearedWhileSignedOutIsIgnored =
    test "cleared_while_signed_out_is_ignored: a clear on an already signed-out tab is a no-op" <|
        \() ->
            Main.adoptExternalAuth Encode.null Nothing
                |> Expect.equal Main.IgnoreExternal


garbageStringIsIgnored : Test
garbageStringIsIgnored =
    test "garbage_string_is_ignored: an undecodable string never logs out or crashes" <|
        \() ->
            Main.adoptExternalAuth (Encode.string "{not-valid-json") (Just (authWith "T0"))
                |> Expect.equal Main.IgnoreExternal


garbageNonStringIsIgnored : Test
garbageNonStringIsIgnored =
    test "garbage_non_string_is_ignored: a non-string, non-null value is a no-op" <|
        \() ->
            Main.adoptExternalAuth (Encode.int 42) (Just (authWith "T0"))
                |> Expect.equal Main.IgnoreExternal


validAuthWhileSignedOutIsIgnored : Test
validAuthWhileSignedOutIsIgnored =
    test "valid_auth_while_signed_out_is_ignored: a signed-out tab does not auto-login from a sibling" <|
        \() ->
            Main.adoptExternalAuth (storedAuthValue "T1") Nothing
                |> Expect.equal Main.IgnoreExternal


recheckNewerStoredTokenAdopts : Test
recheckNewerStoredTokenAdopts =
    test "recheck_newer_stored_token_adopts: on a 401, a newer stored token is adopted instead of logging out" <|
        \() ->
            Main.adoptExternalAuth (storedAuthValue "T1") (Just (authWith "T0-dead"))
                |> Expect.equal (Main.AdoptAuth (authWith "T1"))


recheckSameStoredTokenProceedsToLogout : Test
recheckSameStoredTokenProceedsToLogout =
    test "recheck_same_stored_token_proceeds_to_logout: nothing newer stored -> not adopted (caller logs out)" <|
        \() ->
            Main.adoptExternalAuth (storedAuthValue "T0-dead") (Just (authWith "T0-dead"))
                |> Expect.equal Main.IgnoreExternal


renewalOrigin : Main.PendingLogout
renewalOrigin =
    { draftSaved = False, fromRenewal = True }


pageOrigin : Main.PendingLogout
pageOrigin =
    { draftSaved = False, fromRenewal = False }


{-| P1b: a re-check that ORIGINATED from a consumed renewal tick (a failed silent
refresh) must re-arm renewal when it adopts a newer token — otherwise the session
would have no proactive renewal left.
-}
renewalOriginAdoptReschedules : Test
renewalOriginAdoptReschedules =
    test "renewal_origin_adopt_reschedules: a renewal-origin re-check adopt re-arms renewal" <|
        \() ->
            Main.resolveRecheck (Just renewalOrigin) (Main.AdoptAuth (authWith "T1"))
                |> Expect.equal (Main.ResolveAdopt (authWith "T1") True)


{-| P1b (the bug): a re-check from a PAGE 401 still has its 7h renewal tick armed,
so adopting must NOT reschedule — a second timer per adopt is a self-perpetuating
refresh storm (the contention fights).
-}
pageOriginAdoptDoesNotReschedule : Test
pageOriginAdoptDoesNotReschedule =
    test "page_origin_adopt_does_not_reschedule: a page-origin re-check adopt does NOT re-arm renewal" <|
        \() ->
            Main.resolveRecheck (Just pageOrigin) (Main.AdoptAuth (authWith "T1"))
                |> Expect.equal (Main.ResolveAdopt (authWith "T1") False)


recheckSameTokenForcesLogoutCarryingDraft : Test
recheckSameTokenForcesLogoutCarryingDraft =
    test "recheck_same_token_forces_logout_carrying_draft: no newer token -> force logout, draft notice preserved" <|
        \() ->
            Main.resolveRecheck (Just { draftSaved = True, fromRenewal = False }) Main.IgnoreExternal
                |> Expect.equal (Main.ResolveForceLogout True)


recheckClearedForcesLogout : Test
recheckClearedForcesLogout =
    test "recheck_cleared_forces_logout: a cleared store during a parked expiry forces logout" <|
        \() ->
            Main.resolveRecheck (Just renewalOrigin) Main.LogOutExternally
                |> Expect.equal (Main.ResolveForceLogout False)


{-| P1a (safety half): once a parked intent has been cancelled, a late-arriving
`gotStoredAuth` answer is a no-op — it can NOT log out.
-}
noParkedIntentIsNoop : Test
noParkedIntentIsNoop =
    test "no_parked_intent_is_noop: gotStoredAuth with no parked logout does nothing" <|
        \() ->
            Main.resolveRecheck Nothing Main.IgnoreExternal
                |> Expect.equal Main.ResolveNoop


{-| P1a (the interleave): a page 401 parks a logout; before the answer, a sibling
`storage` event adopts a valid T1 (which MUST clear the parked intent); then the
late re-check answer (same token T1 -> IgnoreExternal) must be a no-op rather than
logging out a tab that just adopted a valid token.

`resolveRecheck` receiving `Nothing` is the observable proof that the cross-tab
adopt cleared the parked intent (had it left `Just`, the same input yields
`ResolveForceLogout` — asserted alongside to pin the regression).

-}
interleaveExternalAdoptCancelsParkedLogout : Test
interleaveExternalAdoptCancelsParkedLogout =
    test "interleave_external_adopt_cancels_parked_logout: adopt-then-recheck must NOT log out" <|
        \() ->
            Expect.all
                [ \() ->
                    Main.resolveRecheck Nothing Main.IgnoreExternal
                        |> Expect.equal Main.ResolveNoop
                , \() ->
                    Main.resolveRecheck (Just pageOrigin) Main.IgnoreExternal
                        |> Expect.equal (Main.ResolveForceLogout False)
                ]
                ()


plainExpiryDoesNotDowngradeDraftSaved : Test
plainExpiryDoesNotDowngradeDraftSaved =
    test "plain_expiry_does_not_downgrade_draft_saved: a later plain expiry keeps a parked draftSaved" <|
        \() ->
            Main.parkPending False False (Just { draftSaved = True, fromRenewal = False })
                |> Expect.equal { draftSaved = True, fromRenewal = False }


draftExpirySetsDraftSaved : Test
draftExpirySetsDraftSaved =
    test "draft_expiry_sets_draft_saved: a draft expiry with no prior intent records draftSaved" <|
        \() ->
            Main.parkPending True False Nothing
                |> Expect.equal { draftSaved = True, fromRenewal = False }


renewalAndDraftOriginsMerge : Test
renewalAndDraftOriginsMerge =
    test "renewal_and_draft_origins_merge: overlapping origins OR their flags (both sticky)" <|
        \() ->
            Main.parkPending False True (Just { draftSaved = True, fromRenewal = False })
                |> Expect.equal { draftSaved = True, fromRenewal = True }
