module PersistFirstLoginTest exposing (suite)

{-| The login credential must never be downstream of an animation. Login
used to park the auth response, play the door dolly-shot, and persist
only when the browser reported the animation done — a report an
occluded window never sends (rAF doesn't fire), leaving the reader
authenticated in memory and anonymous on disk. Persistence now happens
on the same update that decodes the 200; the animation is decoration.
-}

import Expect
import Main
import Navigation.Route as Route exposing (Route(..))
import Page.Login as Login
import ProgramTest exposing (ProgramTest, SimulatedEffect)
import SimulatedEffect.Cmd
import Test exposing (Test, describe, test)
import TestHelpers exposing (simulateAuthResponse)
import Types.User exposing (User)


suite : Test
suite =
    describe "Persist-first login"
        [ describe "a 200 is durable before anything the browser can decline to run"
            [ persistFirstNoAnimationSignal
            , persistFirstBeforeAnyAnimation
            , persistFirstIsTheFirstEffect
            , arrivalIsSignedInImmediately
            ]
        , describe "completeLogin — the only door into an authenticated state"
            [ completeLoginAlwaysPersists
            , completeLoginCarriesTheResponsesToken
            , completeLoginStartsArriving
            ]
        , describe "AuthState — what the arrival stage cannot do"
            [ arrivingIsIndistinguishableFromAuthenticated
            , anonymousHasNoSession
            , settleArrivalIsIdempotent
            , settleArrivalCannotSignOut
            ]
        , describe "redirectAfterLogin — the page they asked for"
            [ bouncedRouteIsCaptured
            , unbouncedRouteIsNotCaptured
            , publicRouteIsNeverCaptured
            , captureMatchesTheBounceForEveryRoute
            ]
        ]


{-| The shell as far as a login is concerned: the login card, plus the
observable consequences of the effects a completed login fires.
-}
type alias ShellModel =
    { page : Login.Model
    , authState : Main.AuthState
    , storedToken : Maybe String
    , effectLog : List Main.LoginEffect
    }


shellInit : ShellModel
shellInit =
    { page = Login.init Login.Fresh
    , authState = Main.Anonymous
    , storedToken = Nothing
    , effectLog = []
    }


{-| Realise one `LoginEffect`, recording what it means. Deliberately total: a new
effect must be classified here rather than silently ignored.
-}
applyEffect : Main.CompletedLogin -> Main.LoginEffect -> ShellModel -> ShellModel
applyEffect arrival effect model =
    let
        logged =
            { model | effectLog = model.effectLog ++ [ effect ] }
    in
    case effect of
        Main.PersistAuth ->
            { logged | storedToken = Just arrival.session.token }

        Main.FetchPlacements ->
            logged

        Main.InitOnboarding ->
            logged

        Main.ScheduleRenewal ->
            logged

        Main.NavigateToRequestedPage ->
            logged

        Main.ArmArrivalBackstop ->
            logged

        Main.PlayDoorAnimation ->
            logged


{-| The shell's update: the real `Login.update`, and — on the real `LoggedIn`
out-message — the real `Main.completeLogin` and the real `Main.loginEffects`.

⚠️ There is no message here that can carry an animation-finished signal. That is
the point: this is the occluded window, in which no such message ever arrives.

-}
shellUpdate : Login.Msg -> ShellModel -> ( ShellModel, SimulatedEffect Login.Msg )
shellUpdate msg model =
    let
        ( newPage, _, outMsg ) =
            Login.update msg model.page

        withPage =
            { model | page = newPage }

        newModel =
            case outMsg of
                Login.LoggedIn authResponse ->
                    let
                        arrival =
                            Main.completeLogin authResponse
                    in
                    List.foldl (applyEffect arrival)
                        { withPage | authState = arrival.authState }
                        arrival.effects

                _ ->
                    withPage
    in
    ( newModel, TestHelpers.loginEffects msg model.page )


shellProgram : ProgramTest ShellModel Login.Msg (SimulatedEffect Login.Msg)
shellProgram =
    ProgramTest.createElement
        { init = \() -> ( shellInit, SimulatedEffect.Cmd.none )
        , update = shellUpdate
        , view = \model -> Login.view model.page
        }
        |> ProgramTest.withSimulatedEffects identity
        |> ProgramTest.start ()


{-| Sign in with valid credentials and let the server answer `200`. Nothing after
this point delivers an animation-finished signal.
-}
signIn : ProgramTest ShellModel Login.Msg (SimulatedEffect Login.Msg)
signIn =
    shellProgram
        |> ProgramTest.fillIn "email" "Email" "reader@stacks.dev"
        |> ProgramTest.fillIn "password" "Password" "secret123"
        |> ProgramTest.clickButton "Enter the Stacks"
        |> ProgramTest.simulateHttpResponse "POST"
            "/api/auth/login"
            (simulateAuthResponse "jwt-token" "user-1" "reader@stacks.dev" "A Reader")


persistFirstNoAnimationSignal : Test
persistFirstNoAnimationSignal =
    test "persist_first_no_animation_signal: the token is stored with no animation message ever delivered" <|
        \() ->
            signIn
                |> ProgramTest.expectModel
                    (\model ->
                        model.storedToken
                            |> Expect.equal (Just "jwt-token")
                    )


persistFirstBeforeAnyAnimation : Test
persistFirstBeforeAnyAnimation =
    test "persist_first_before_any_animation: PersistAuth is realised before PlayDoorAnimation" <|
        \() ->
            signIn
                |> ProgramTest.expectModel
                    (\model ->
                        Expect.all
                            [ \log ->
                                indexOf Main.PersistAuth log
                                    |> Expect.notEqual Nothing
                            , \log ->
                                indexOf Main.PlayDoorAnimation log
                                    |> Expect.notEqual Nothing
                            , \log ->
                                Expect.equal True
                                    (Maybe.map2 (<)
                                        (indexOf Main.PersistAuth log)
                                        (indexOf Main.PlayDoorAnimation log)
                                        |> Maybe.withDefault False
                                    )
                            ]
                            model.effectLog
                    )


persistFirstIsTheFirstEffect : Test
persistFirstIsTheFirstEffect =
    test "persist_first_is_first: nothing at all is fired before the credential is durable" <|
        \() ->
            signIn
                |> ProgramTest.expectModel
                    (\model ->
                        List.head model.effectLog
                            |> Expect.equal (Just Main.PersistAuth)
                    )


arrivalIsSignedInImmediately : Test
arrivalIsSignedInImmediately =
    test "persist_first_signed_in: the reader is signed in on the same step, with the animation still owed" <|
        \() ->
            signIn
                |> ProgramTest.expectModel
                    (\model ->
                        Main.currentAuth model.authState
                            |> Maybe.map .token
                            |> Expect.equal (Just "jwt-token")
                    )


fakeResponse : Main.Auth -> { token : String, userId : String, email : String, displayName : String, handle : String, role : String, consentAnalytics : Bool, consentWritingAssistant : Bool }
fakeResponse auth =
    { token = auth.token
    , userId = auth.user.id
    , email = auth.user.email
    , displayName = auth.user.displayName
    , handle = auth.user.handle
    , role = auth.user.role
    , consentAnalytics = auth.user.consentAnalytics
    , consentWritingAssistant = auth.user.consentWritingAssistant
    }


readerUser : User
readerUser =
    { id = "u1"
    , email = "reader@stacks.dev"
    , displayName = "A Reader"
    , handle = "a_reader"
    , role = "user"
    , countryCode = Nothing
    , city = Nothing
    , consentAnalytics = False
    , consentWritingAssistant = False
    }


readerAuth : Main.Auth
readerAuth =
    { user = readerUser, token = "jwt-token" }


completeLoginAlwaysPersists : Test
completeLoginAlwaysPersists =
    test "completeLogin cannot produce an authenticated state without the effect that saves it" <|
        \() ->
            Main.completeLogin (fakeResponse readerAuth)
                |> (\arrival ->
                        Expect.all
                            [ \a -> Expect.equal True (List.member Main.PersistAuth a.effects)
                            , \a -> Expect.notEqual Nothing (Main.currentAuth a.authState)
                            ]
                            arrival
                   )


completeLoginCarriesTheResponsesToken : Test
completeLoginCarriesTheResponsesToken =
    test "completeLogin's session is the token the server issued" <|
        \() ->
            (Main.completeLogin (fakeResponse readerAuth)).session.token
                |> Expect.equal "jwt-token"


completeLoginStartsArriving : Test
completeLoginStartsArriving =
    test "completeLogin starts in Arriving — the door ornament is still owed a signal" <|
        \() ->
            (Main.completeLogin (fakeResponse readerAuth)).authState
                |> Expect.equal (Main.Arriving readerAuth)


arrivingIsIndistinguishableFromAuthenticated : Test
arrivingIsIndistinguishableFromAuthenticated =
    test "auth_state_arriving_is_signed_in: an unfinished animation cannot make a reader look signed out" <|
        \() ->
            Main.currentAuth (Main.Arriving readerAuth)
                |> Expect.equal (Main.currentAuth (Main.Authenticated readerAuth))


anonymousHasNoSession : Test
anonymousHasNoSession =
    test "Anonymous carries no session" <|
        \() ->
            Main.currentAuth Main.Anonymous |> Expect.equal Nothing


settleArrivalIsIdempotent : Test
settleArrivalIsIdempotent =
    test "settleArrival survives the signal arriving twice (port AND backstop)" <|
        \() ->
            Main.settleArrival (Main.settleArrival (Main.Arriving readerAuth))
                |> Expect.equal (Main.Authenticated readerAuth)


settleArrivalCannotSignOut : Test
settleArrivalCannotSignOut =
    test "settle_cannot_sign_out: a stray settle on a signed-out app is a no-op" <|
        \() ->
            Main.settleArrival Main.Anonymous |> Expect.equal Main.Anonymous


bouncedRouteIsCaptured : Test
bouncedRouteIsCaptured =
    test "redirect_captured: a signed-out reader deep-linking to /upload is remembered" <|
        \() ->
            Main.loginRedirectFor Upload Nothing |> Expect.equal (Just Upload)


unbouncedRouteIsNotCaptured : Test
unbouncedRouteIsNotCaptured =
    test "a signed-in reader is not bounced, so nothing is remembered" <|
        \() ->
            Main.loginRedirectFor Upload (Just readerAuth) |> Expect.equal Nothing


publicRouteIsNeverCaptured : Test
publicRouteIsNeverCaptured =
    test "a public route is never a redirect target" <|
        \() ->
            Main.loginRedirectFor Route.Login Nothing |> Expect.equal Nothing


{-| Anti-drift: the capture and the bounce must agree for EVERY route. If someone
adds a protected route and the capture stops matching `requiresAuth`, the reader
starts landing somewhere they did not ask for — silently.
-}
captureMatchesTheBounceForEveryRoute : Test
captureMatchesTheBounceForEveryRoute =
    test "redirect_matches_bounce: capture happens exactly when the reader is bounced" <|
        \() ->
            let
                routes =
                    [ Home
                    , Route.Login
                    , Library
                    , AntiLibrary
                    , WishList
                    , ReadingPile
                    , LookingForHome
                    , Upload
                    , Search
                    , SettingsProfile
                    , Insights
                    , Catalogue
                    , MarketplaceBrowse
                    , BlogArchive
                    , CostTransparency
                    , NotFound
                    ]

                disagreeing =
                    List.filter
                        (\route ->
                            (Main.loginRedirectFor route Nothing /= Nothing)
                                /= Main.requiresAuth route
                        )
                        routes
            in
            disagreeing |> Expect.equalLists []


indexOf : a -> List a -> Maybe Int
indexOf target list =
    list
        |> List.indexedMap Tuple.pair
        |> List.filter (\( _, item ) -> item == target)
        |> List.head
        |> Maybe.map Tuple.first
