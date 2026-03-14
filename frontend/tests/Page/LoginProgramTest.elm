module Page.LoginProgramTest exposing (suite)

{-| Program tests for Page.Login using elm-program-test.

These tests exercise the full Login page lifecycle through
simulated user interactions and HTTP responses, verifying
the door metaphor animation, form validation, mode switching,
and error display.

-}

import Http
import Page.Login as Login exposing (Msg(..))
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers exposing (loginProgram, simulateAuthErrorResponse, simulateAuthResponse)


{-| Helper to start a login program test.
-}
startLogin : ProgramTest.ProgramTest Login.Model Login.Msg (ProgramTest.SimulatedEffect Login.Msg)
startLogin =
    ProgramTest.start () loginProgram


suite : Test
suite =
    describe "Page.Login (ProgramTest)"
        [ loginFormSubmitShowsSpinner
        , loginSuccessDoorAnimation
        , loginFailureShowsError
        , switchToRegisterShowsDisplayName
        , switchBackToLoginHidesDisplayName
        , submitDisabledDuringLoading
        , submitDisabledDuringDoorAnimation
        ]


loginFormSubmitShowsSpinner : Test
loginFormSubmitShowsSpinner =
    test "login_form_submit_shows_spinner: fill email and password, click submit -> spinner shown" <|
        \() ->
            startLogin
                |> ProgramTest.fillIn "email" "Email" "reader@stacks.dev"
                |> ProgramTest.fillIn "password" "Password" "secret123"
                |> ProgramTest.clickButton "Enter the Stacks"
                |> ProgramTest.expectViewHas
                    [ Selector.class "spinner" ]


loginSuccessDoorAnimation : Test
loginSuccessDoorAnimation =
    test "login_success_door_animation: successful auth -> door opening and open classes applied" <|
        \() ->
            startLogin
                |> ProgramTest.fillIn "email" "Email" "reader@stacks.dev"
                |> ProgramTest.fillIn "password" "Password" "secret123"
                |> ProgramTest.clickButton "Enter the Stacks"
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/auth/login"
                    (simulateAuthResponse "jwt-token" "user-1" "reader@stacks.dev" "A Reader")
                -- After successful auth, a 200ms delay triggers DoorOpeningStarted
                |> ProgramTest.advanceTime 200
                |> ProgramTest.ensureViewHas
                    [ Selector.class "login-door--opening" ]
                -- After 1200ms more, DoorFullyOpened fires
                |> ProgramTest.advanceTime 1200
                |> ProgramTest.expectViewHas
                    [ Selector.class "login-door--open" ]


loginFailureShowsError : Test
loginFailureShowsError =
    test "login_failure_shows_error: failed auth -> error message rendered with themed text" <|
        \() ->
            startLogin
                |> ProgramTest.fillIn "email" "Email" "reader@stacks.dev"
                |> ProgramTest.fillIn "password" "Password" "wrong-password"
                |> ProgramTest.clickButton "Enter the Stacks"
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/auth/login"
                    (simulateAuthErrorResponse 401)
                |> ProgramTest.ensureViewHas
                    [ Selector.class "login-form__error" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "The door remains shut. Invalid credentials." ]


switchToRegisterShowsDisplayName : Test
switchToRegisterShowsDisplayName =
    test "switch_to_register_shows_display_name: click Register tab -> display name field shown" <|
        \() ->
            startLogin
                |> ProgramTest.clickButton "Register"
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Display Name" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Register for entry to the collection" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Request Entry" ]


switchBackToLoginHidesDisplayName : Test
switchBackToLoginHidesDisplayName =
    test "switch_back_to_login_hides_display_name: Register -> Sign In -> display name field hidden" <|
        \() ->
            startLogin
                |> ProgramTest.clickButton "Register"
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Display Name" ]
                |> ProgramTest.clickButton "Sign In"
                |> ProgramTest.ensureViewHasNot
                    [ Selector.text "Display Name" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Present your credentials to enter" ]


submitDisabledDuringLoading : Test
submitDisabledDuringLoading =
    test "submit_disabled_during_loading: button is disabled while request is in flight" <|
        \() ->
            startLogin
                |> ProgramTest.fillIn "email" "Email" "reader@stacks.dev"
                |> ProgramTest.fillIn "password" "Password" "secret123"
                |> ProgramTest.clickButton "Enter the Stacks"
                |> ProgramTest.expectViewHas
                    [ Selector.disabled True ]


submitDisabledDuringDoorAnimation : Test
submitDisabledDuringDoorAnimation =
    test "submit_disabled_during_door_animation: button is disabled during door opening" <|
        \() ->
            startLogin
                |> ProgramTest.fillIn "email" "Email" "reader@stacks.dev"
                |> ProgramTest.fillIn "password" "Password" "secret123"
                |> ProgramTest.clickButton "Enter the Stacks"
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/auth/login"
                    (simulateAuthResponse "jwt-token" "user-1" "reader@stacks.dev" "A Reader")
                |> ProgramTest.advanceTime 200
                |> ProgramTest.ensureViewHas
                    [ Selector.class "login-door--opening" ]
                |> ProgramTest.expectViewHas
                    [ Selector.disabled True ]
