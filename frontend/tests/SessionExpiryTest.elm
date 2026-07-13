module SessionExpiryTest exposing (suite)

{-| Tests for Issue #173 Phase 2 — global session-expiry interceptor + proactive
silent renewal.


## Seam note (read before extending)

`Main.elm` is a `Browser.application` with a real `Nav.Key` and real ports plus
real `Api.*` `Cmd`s. As documented in `MainNavTest`, its full update loop cannot
be driven by `elm-program-test` (effects are opaque `Cmd Msg`), and any function
taking `Main.Model` cannot be unit-tested because `Model` embeds an
unconstructable `Nav.Key`. So the interceptor is tested at the seams that ARE
reachable:

  - **Page precondition (Scenario 1):** an authenticated 401 must stop being
    swallowed as `NoOut` and bubble a distinct `OutMsg` to `Main`. Asserted as
    `OutMsg /= NoOut` on the two representative authed pages.
  - **Exclusion (Scenario 2):** a login 401 stays local (invalid-credentials, no
    global notice / redirect).
  - **Renewal (Scenarios 3 & 4):** driven through a `POST /api/auth/refresh`
    `SimulatedEffect` harness whose success path calls the real key-free
    `Main.renewAuthToken`; success adopts the new token (no logout), failure
    clears auth (the `sessionExpired` fall-through).
  - **Notice + scheduling:** `Login.expiredInit` renders the distinct notice
    (the visible outcome of `Main.sessionExpired`'s flag), and `Main.loginEffects`
    includes `ScheduleRenewal` (renewal is armed on login).

`Main.sessionExpired`'s full redirect + `clearAuth` port (needs `Nav.Key`) is
covered by the deployed E2E gate (`e2e/tests/auth.spec.ts`).

-}

import Api
import Expect
import Html
import Http
import Json.Decode as Decode
import Main
import Page.BookDetail as BookDetail
import Page.Bookshelf as Bookshelf
import Page.Login as Login
import ProgramTest exposing (SimulatedEffect)
import SimulatedEffect.Cmd
import SimulatedEffect.Http
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers exposing (loginProgram, simulateAuthErrorResponse, simulateAuthResponse)
import Types.User exposing (User)


suite : Test
suite =
    describe "Session expiry interceptor + renewal (Issue #173 Phase 2)"
        [ describe "Scenario 1 — 401 on an authed page bubbles to the global interceptor"
            [ bookshelf401BubblesOutMsg
            , bookDetail401BubblesOutMsg
            , bookshelfSuccessStaysLocal
            , bookshelf403StaysLocal
            ]
        , describe "Scenario 2 — login 401 stays LOCAL (exclusion regression guard)"
            [ loginPage401StaysLocalInvalidCredentials
            ]
        , describe "Scenario 3 — silent renewal success renews the token"
            [ renewalSuccessAdoptsNewToken
            , renewalSuccessKeepsUserLoggedIn
            , renewAuthTokenSwapsTokenKeepsUser
            , loginArmsRenewal
            ]
        , describe "Scenario 4 — silent renewal failure falls through to the interceptor"
            [ renewalFailureClearsAuth
            ]
        , describe "Notice — the redirect target shows a distinct session-expired message"
            [ expiredInitRendersDistinctNotice
            , freshInitHasNoNotice
            ]
        ]



-- SCENARIO 1


{-| RED: an authenticated 401 from the bookshelf load must NOT be swallowed as
`NoOut`. Today `Bookshelf.update` routes `Err (BadStatus 401)` through the
catch-all `Err err ->` branch and returns `NoOut` (Bookshelf.elm:162), so the
global interceptor never fires. After the interceptor is wired, a 401 emits the
new `SessionExpired` variant instead — i.e. anything but `NoOut`.

We assert `notEqual NoOut` rather than naming `SessionExpired` so this compiles
against current code and fails on the assertion (RED), then goes green once the
page bubbles the distinct signal to `Main`.

-}
bookshelf401BubblesOutMsg : Test
bookshelf401BubblesOutMsg =
    test "bookshelf_401_bubbles_out: authed 401 no longer resolves to NoOut" <|
        \() ->
            let
                ( model, _ ) =
                    Bookshelf.init Bookshelf.libraryConfig (Just "auth-token") "user-1"

                ( _, _, outMsg ) =
                    Bookshelf.update
                        (Bookshelf.ShelvesLoaded (Err (Http.BadStatus 401)))
                        model
            in
            outMsg |> Expect.notEqual Bookshelf.NoOut


{-| RED: same contract for the second representative authed page. A 401 on the
book-detail load currently lands in `Err err ->` and returns `NoOut`
(BookDetail.elm:220); it must instead bubble a distinct `OutMsg` for the shared
interceptor.
-}
bookDetail401BubblesOutMsg : Test
bookDetail401BubblesOutMsg =
    test "book_detail_401_bubbles_out: authed 401 no longer resolves to NoOut" <|
        \() ->
            let
                ( model, _ ) =
                    BookDetail.init "book-1" (Just "auth-token") Nothing

                ( _, _, outMsg ) =
                    BookDetail.update
                        (BookDetail.BookLoaded (Err (Http.BadStatus 401)))
                        model
                        (Just "auth-token")
            in
            outMsg |> Expect.notEqual BookDetail.NoOut


{-| GREEN guard: a successful load must stay LOCAL (`NoOut`) — the interceptor
must only capture 401s, never ordinary success. Passes today and after impl.
-}
bookshelfSuccessStaysLocal : Test
bookshelfSuccessStaysLocal =
    test "bookshelf_success_stays_local: a successful load stays NoOut" <|
        \() ->
            let
                ( model, _ ) =
                    Bookshelf.init Bookshelf.libraryConfig (Just "auth-token") "user-1"

                ( _, _, outMsg ) =
                    Bookshelf.update (Bookshelf.ShelvesLoaded (Ok [])) model
            in
            outMsg |> Expect.equal Bookshelf.NoOut


{-| GREEN guard: a 403 is the age-gate path, NOT session expiry. It must stay
LOCAL (`NoOut`, opening the age gate) so the interceptor does not over-capture.
Passes today and must remain green after impl.
-}
bookshelf403StaysLocal : Test
bookshelf403StaysLocal =
    test "bookshelf_403_stays_local: a 403 age-gate stays NoOut (not intercepted)" <|
        \() ->
            let
                ( model, _ ) =
                    Bookshelf.init Bookshelf.libraryConfig (Just "auth-token") "user-1"

                ( _, _, outMsg ) =
                    Bookshelf.update
                        (Bookshelf.ShelvesLoaded (Err (Http.BadStatus 403)))
                        model
            in
            outMsg |> Expect.equal Bookshelf.NoOut



-- SCENARIO 2 (exclusion)


{-| Exclusion guard: a 401 from `/api/auth/login` is invalid-credentials, NOT a
session expiry. It must be handled LOCALLY by `Page.Login` — the login form
stays put, shows its themed invalid-credentials copy, and never surfaces the
global "session expired" notice or redirects. This PASSES today; it is the
regression guard proving the interceptor does not capture the login path.
-}
loginPage401StaysLocalInvalidCredentials : Test
loginPage401StaysLocalInvalidCredentials =
    test "login_401_stays_local: login 401 shows local invalid-credentials, not a session-expired notice" <|
        \() ->
            ProgramTest.start () loginProgram
                |> ProgramTest.fillIn "email" "Email" "reader@stacks.dev"
                |> ProgramTest.fillIn "password" "Password" "wrong-password"
                |> ProgramTest.clickButton "Enter the Stacks"
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/auth/login"
                    (simulateAuthErrorResponse 401)
                |> ProgramTest.ensureViewHas
                    [ Selector.text "The door remains shut. Invalid credentials." ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Present your credentials to enter" ]
                |> ProgramTest.expectViewHasNot
                    [ Selector.text "closed your session" ]



-- SCENARIO 3 & 4 — SILENT RENEWAL (via a POST /api/auth/refresh harness)


{-| A user whose token is nearing expiry. The renewal harness starts here.
-}
startingUser : User
startingUser =
    { id = "user-1"
    , email = "reader@stacks.dev"
    , displayName = "A Reader"
    , role = "user"
    , countryCode = Nothing
    , city = Nothing
    , consentWritingAssistant = False
    }


startingAuth : Main.Auth
startingAuth =
    { user = startingUser, token = "old.token" }


{-| Drivers for the renewal harness.
-}
type RenewMsg
    = TriggerRenewal
    | RefreshResult (Result Http.Error Api.AuthResponse)


{-| Decoder mirroring `Api.authResponseDecoder` — refresh's 200 body is
byte-identical to login's (contract confirmed), so the same shape decodes it.
-}
authResponseDecoder : Decode.Decoder Api.AuthResponse
authResponseDecoder =
    Decode.map6 Api.AuthResponse
        (Decode.field "token" Decode.string)
        (Decode.at [ "user", "id" ] Decode.string)
        (Decode.at [ "user", "email" ] Decode.string)
        (Decode.at [ "user", "display_name" ] Decode.string)
        (Decode.oneOf
            [ Decode.at [ "user", "role" ] Decode.string
            , Decode.succeed "user"
            ]
        )
        (Decode.oneOf
            [ Decode.at [ "user", "consent_writing_assistant" ] Decode.bool
            , Decode.succeed False
            ]
        )


{-| Effect translation for the harness: `TriggerRenewal` issues the real
`POST /api/auth/refresh` (Bearer token) that `Api.refresh` builds; results feed
back as `RefreshResult`.
-}
renewEffects : RenewMsg -> Maybe Main.Auth -> SimulatedEffect RenewMsg
renewEffects msg model =
    case ( msg, model ) of
        ( TriggerRenewal, Just auth ) ->
            SimulatedEffect.Http.request
                { method = "POST"
                , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ auth.token) ]
                , url = "/api/auth/refresh"
                , body = SimulatedEffect.Http.emptyBody
                , expect = SimulatedEffect.Http.expectJson RefreshResult authResponseDecoder
                , timeout = Nothing
                , tracker = Nothing
                }

        _ ->
            SimulatedEffect.Cmd.none


{-| Harness update. The success path calls the REAL `Main.renewAuthToken`; the
failure path mirrors `Main.sessionExpired`'s auth-clearing (the interceptor
fall-through).
-}
renewUpdate : RenewMsg -> Maybe Main.Auth -> Maybe Main.Auth
renewUpdate msg model =
    case msg of
        TriggerRenewal ->
            model

        RefreshResult (Ok authResponse) ->
            Maybe.map (Main.renewAuthToken authResponse) model

        RefreshResult (Err _) ->
            Nothing


{-| A ProgramTest over `Maybe Main.Auth`, rendering the current token (or a
signed-out marker) so renewal outcomes are observable in the view.
-}
renewProgram : ProgramTest.ProgramDefinition () (Maybe Main.Auth) RenewMsg (SimulatedEffect RenewMsg)
renewProgram =
    ProgramTest.createElement
        { init = \() -> ( Just startingAuth, SimulatedEffect.Cmd.none )
        , update = \msg model -> ( renewUpdate msg model, renewEffects msg model )
        , view =
            \model ->
                case model of
                    Just auth ->
                        Html.text ("token:" ++ auth.token)

                    Nothing ->
                        Html.text "signed-out"
        }
        |> ProgramTest.withSimulatedEffects identity


renewalSuccessAdoptsNewToken : Test
renewalSuccessAdoptsNewToken =
    test "renewal_success_adopts_new_token: a 200 from /api/auth/refresh swaps in the new token" <|
        \() ->
            ProgramTest.start () renewProgram
                |> ProgramTest.update TriggerRenewal
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/auth/refresh"
                    (simulateAuthResponse "new.token" "user-1" "reader@stacks.dev" "A Reader")
                |> ProgramTest.expectViewHas [ Selector.text "token:new.token" ]


renewalSuccessKeepsUserLoggedIn : Test
renewalSuccessKeepsUserLoggedIn =
    test "renewal_success_keeps_user_logged_in: a successful renewal does NOT sign the user out" <|
        \() ->
            ProgramTest.start () renewProgram
                |> ProgramTest.update TriggerRenewal
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/auth/refresh"
                    (simulateAuthResponse "new.token" "user-1" "reader@stacks.dev" "A Reader")
                |> ProgramTest.expectViewHasNot [ Selector.text "signed-out" ]


renewalFailureClearsAuth : Test
renewalFailureClearsAuth =
    test "renewal_failure_clears_auth: a 401 from /api/auth/refresh falls through to session expiry" <|
        \() ->
            ProgramTest.start () renewProgram
                |> ProgramTest.update TriggerRenewal
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/auth/refresh"
                    (simulateAuthErrorResponse 401)
                |> ProgramTest.expectViewHas [ Selector.text "signed-out" ]


{-| Unit test of the real key-free renewal transform: it swaps in the refreshed
token while preserving the authenticated user (identity/role unchanged).
-}
renewAuthTokenSwapsTokenKeepsUser : Test
renewAuthTokenSwapsTokenKeepsUser =
    test "renew_auth_token_swaps_token_keeps_user" <|
        \() ->
            let
                refreshed =
                    Main.renewAuthToken
                        { token = "new.token"
                        , userId = "ignored"
                        , email = "ignored@example.com"
                        , displayName = "Ignored"
                        , role = "owner"
                        , consentWritingAssistant = False
                        }
                        startingAuth
            in
            Expect.all
                [ \r -> r.token |> Expect.equal "new.token"
                , \r -> r.user |> Expect.equal startingUser
                ]
                refreshed


{-| Renewal is armed on login: `loginEffects` (fired for every completed login)
schedules a renewal, mirroring what stored-auth `init` does.
-}
loginArmsRenewal : Test
loginArmsRenewal =
    test "login_arms_renewal: loginEffects schedules a proactive renewal" <|
        \() ->
            List.member Main.ScheduleRenewal Main.loginEffects
                |> Expect.equal True



-- NOTICE — the distinct session-expired message on the redirect target


{-| The redirect target of `Main.sessionExpired` (`Login.expiredInit`) renders a
notice distinct from invalid-credentials.
-}
expiredInitRendersDistinctNotice : Test
expiredInitRendersDistinctNotice =
    test "expired_init_renders_distinct_notice: the expired-notice login state shows the session-expired message" <|
        \() ->
            ProgramTest.start () (loginModelProgram Login.expiredInit)
                |> ProgramTest.expectViewHas
                    [ Selector.text "The library closed your session for safekeeping — sign in again to return." ]


{-| A fresh (non-expiry) login must NOT show the session-expired notice.
-}
freshInitHasNoNotice : Test
freshInitHasNoNotice =
    test "fresh_init_has_no_notice: an ordinary login has no session-expired notice" <|
        \() ->
            ProgramTest.start () (loginModelProgram Login.init)
                |> ProgramTest.expectViewHasNot
                    [ Selector.text "The library closed your session for safekeeping — sign in again to return." ]


{-| A minimal Login ProgramTest seeded with a specific starting model, so the
view of `Login.expiredInit` vs `Login.init` can be asserted directly.
-}
loginModelProgram : Login.Model -> ProgramTest.ProgramDefinition () Login.Model Login.Msg (SimulatedEffect Login.Msg)
loginModelProgram startModel =
    ProgramTest.createElement
        { init = \() -> ( startModel, SimulatedEffect.Cmd.none )
        , update = \msg model -> ( sansEffect (Login.update msg model), SimulatedEffect.Cmd.none )
        , view = Login.view
        }
        |> ProgramTest.withSimulatedEffects identity


sansEffect : ( Login.Model, cmd, out ) -> Login.Model
sansEffect ( model, _, _ ) =
    model
