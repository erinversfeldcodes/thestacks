module SessionExpiryTest exposing (suite)

{-| Global session-expiry interceptor + proactive silent renewal. Main's
full update loop cannot be program-tested (real Nav.Key, opaque Cmds),
so the seam is tested pure: the interceptor claims authed 401s, expiry
stashes the current route for the post-login return, and renewal fires
ahead of the deadline without user-visible state changes.
-}

import Api
import Expect
import Html
import Http
import Main
import Navigation.Route as Route
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
    describe "Session expiry interceptor + renewal"
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
        , describe "— an expiry bounce remembers the page it bounced off"
            [ expiryCapturesThePageTheReaderWasOn
            , expiryCaptureSurvivesTheRedirectToLogin
            , ordinaryNavigationToLoginCapturesNothing
            , expiryOffAPublicPageCapturesNothing
            , routeGuardBounceStillCaptures
            ]
        ]


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
                        (Bookshelf.ShelvesLoaded (Bookshelf.requestKey Bookshelf.libraryConfig) (Err (Http.BadStatus 401)))
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
                    Bookshelf.update (Bookshelf.ShelvesLoaded (Bookshelf.requestKey Bookshelf.libraryConfig) (Ok { shelves = [], visibility = "owner" })) model
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
                        (Bookshelf.ShelvesLoaded (Bookshelf.requestKey Bookshelf.libraryConfig) (Err (Http.BadStatus 403)))
                        model
            in
            outMsg |> Expect.equal Bookshelf.NoOut


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


{-| A user whose token is nearing expiry. The renewal harness starts here.
-}
startingUser : User
startingUser =
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


startingAuth : Main.Auth
startingAuth =
    { user = startingUser, token = "old.token" }


{-| Drivers for the renewal harness.
-}
type RenewMsg
    = TriggerRenewal
    | RefreshResult (Result Http.Error Api.AuthResponse)


{-| Effect translation for the harness: `TriggerRenewal` issues the real
`POST /api/auth/refresh` (Bearer token) that `Api.refresh` builds, decoded with
the REAL `Api.authResponseDecoder` — refresh's 200 body is byte-identical to
login's (contract confirmed), so the same decoder reads it. A hand-mirrored
copy used to live here; it is exactly the second-source-of-truth that let the
upload wire format drift unnoticed. Results feed back as
`RefreshResult`.
-}
renewEffects : RenewMsg -> Maybe Main.Auth -> SimulatedEffect RenewMsg
renewEffects msg model =
    case ( msg, model ) of
        ( TriggerRenewal, Just auth ) ->
            TestHelpers.authedRequestFromSpec Api.refreshRequest
                auth.token
                (SimulatedEffect.Http.expectJson RefreshResult Api.authResponseDecoder)

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
                |> ProgramTest.expectViewHasNot [ Selector.text "closed your session" ]


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
                        , handle = "ignored"
                        , role = "owner"
                        , consentAnalytics = False
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


{-| The redirect target of the expiry path — a login card built with the
`SessionExpired` arrival — renders a notice distinct from invalid-credentials.
-}
expiredInitRendersDistinctNotice : Test
expiredInitRendersDistinctNotice =
    test "expired_init_renders_distinct_notice: the expired-notice login state shows the session-expired message" <|
        \() ->
            ProgramTest.start () (loginModelProgram (Login.init (Login.SessionExpired { draftSaved = False })))
                |> ProgramTest.expectViewHas
                    [ Selector.text "The library closed your session for safekeeping — sign in again to return." ]


{-| A fresh (non-expiry) login must NOT show the session-expired notice.
-}
freshInitHasNoNotice : Test
freshInitHasNoNotice =
    test "fresh_init_has_no_notice: an ordinary login has no session-expired notice" <|
        \() ->
            ProgramTest.start () (loginModelProgram (Login.init Login.Fresh))
                |> ProgramTest.expectViewHasNot
                    [ Selector.text "The library closed your session for safekeeping — sign in again to return." ]


{-| A minimal Login ProgramTest seeded with a specific starting model, so the
view of a `SessionExpired` arrival vs a `Fresh` one can be asserted directly.
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


{-| The reader was on `/settings/password` when the session died.
-}
expiryCapturesThePageTheReaderWasOn : Test
expiryCapturesThePageTheReaderWasOn =
    test "expiry_captures_the_page_the_reader_was_on: an expiry bounce off a settings form remembers the form" <|
        \() ->
            Main.redirectAfterNavigation
                { arrivingAt = Route.Login
                , leaving = Route.SettingsPassword
                , sessionExpiring = True
                , auth = Nothing
                }
                |> Expect.equal (Just Route.SettingsPassword)


{-| The same for a half-finished upload — the journey named.
-}
expiryCaptureSurvivesTheRedirectToLogin : Test
expiryCaptureSurvivesTheRedirectToLogin =
    test "expiry_capture_survives_the_redirect_to_login: /upload is remembered across the push to /login" <|
        \() ->
            Main.redirectAfterNavigation
                { arrivingAt = Route.Login
                , leaving = Route.Upload
                , sessionExpiring = True
                , auth = Nothing
                }
                |> Expect.equal (Just Route.Upload)


{-| Control: someone who clicks "Sign in" of their own accord is not being
bounced off anything, and must not be sent somewhere they did not ask for.
-}
ordinaryNavigationToLoginCapturesNothing : Test
ordinaryNavigationToLoginCapturesNothing =
    test "ordinary_navigation_to_login_captures_nothing: a deliberate visit to /login remembers nothing" <|
        \() ->
            Main.redirectAfterNavigation
                { arrivingAt = Route.Login
                , leaving = Route.SettingsPassword
                , sessionExpiring = False
                , auth = Nothing
                }
                |> Expect.equal Nothing


{-| Control: an expiry while reading a PUBLIC page captures nothing. There is
nothing to return them to that they cannot reach signed out.
-}
expiryOffAPublicPageCapturesNothing : Test
expiryOffAPublicPageCapturesNothing =
    test "expiry_off_a_public_page_captures_nothing: expiry on /about remembers nothing" <|
        \() ->
            Main.redirectAfterNavigation
                { arrivingAt = Route.Login
                , leaving = Route.About
                , sessionExpiring = True
                , auth = Nothing
                }
                |> Expect.equal Nothing


{-| Control: the ORIGINAL route-guard bounce still works. This is the
behaviour the expiry branch must not have broken.
-}
routeGuardBounceStillCaptures : Test
routeGuardBounceStillCaptures =
    test "route_guard_bounce_still_captures: an anonymous visit to /upload is still remembered" <|
        \() ->
            Main.redirectAfterNavigation
                { arrivingAt = Route.Upload
                , leaving = Route.Home
                , sessionExpiring = False
                , auth = Nothing
                }
                |> Expect.equal (Just Route.Upload)
