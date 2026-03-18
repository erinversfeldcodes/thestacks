module Page.LoginProgramTest exposing (suite)

{-| Program tests for Page.Login using elm-program-test.

These tests exercise the full Login page lifecycle through
simulated user interactions and HTTP responses, verifying
the WAAPI port-driven transition, form validation, mode switching,
and error display.

-}

import Page.Login as Login
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
        , loginSuccessTransition
        , loginFailureShowsError
        , switchToRegisterShowsDisplayName
        , switchBackToLoginHidesDisplayName
        , submitDisabledDuringLoading
        , submitDisabledDuringTransition
        , invalidEmailShowsErrorHint
        , validEmailShowsValidState
        , modeSwitchResetsValidation
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


loginSuccessTransition : Test
loginSuccessTransition =
    test "login_success_transition: successful auth -> submit button disabled during transition" <|
        \() ->
            startLogin
                |> ProgramTest.fillIn "email" "Email" "reader@stacks.dev"
                |> ProgramTest.fillIn "password" "Password" "secret123"
                |> ProgramTest.clickButton "Enter the Stacks"
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/auth/login"
                    (simulateAuthResponse "jwt-token" "user-1" "reader@stacks.dev" "A Reader")
                |> ProgramTest.expectViewHas
                    [ Selector.class "login-card__submit"
                    , Selector.disabled True
                    ]


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
                    [ Selector.class "login-card__error" ]
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


submitDisabledDuringTransition : Test
submitDisabledDuringTransition =
    test "submit_disabled_during_transition: button is disabled during WAAPI transition" <|
        \() ->
            startLogin
                |> ProgramTest.fillIn "email" "Email" "reader@stacks.dev"
                |> ProgramTest.fillIn "password" "Password" "secret123"
                |> ProgramTest.clickButton "Enter the Stacks"
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/auth/login"
                    (simulateAuthResponse "jwt-token" "user-1" "reader@stacks.dev" "A Reader")
                |> ProgramTest.expectViewHas
                    [ Selector.class "login-card__submit"
                    , Selector.disabled True
                    ]


invalidEmailShowsErrorHint : Test
invalidEmailShowsErrorHint =
    test "invalid_email_shows_error_hint: typing invalid email shows error hint text" <|
        \() ->
            startLogin
                |> ProgramTest.fillIn "email" "Email" "nope"
                |> ProgramTest.expectViewHas
                    [ Selector.text "Please enter a valid email address" ]


validEmailShowsValidState : Test
validEmailShowsValidState =
    test "valid_email_shows_valid_state: typing valid email shows valid hint" <|
        \() ->
            startLogin
                |> ProgramTest.fillIn "email" "Email" "reader@stacks.dev"
                |> ProgramTest.expectViewHas
                    [ Selector.class "login-card__field--valid" ]


modeSwitchResetsValidation : Test
modeSwitchResetsValidation =
    test "mode_switch_resets_validation: switching mode resets validation to pristine" <|
        \() ->
            startLogin
                |> ProgramTest.fillIn "email" "Email" "nope"
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Please enter a valid email address" ]
                |> ProgramTest.clickButton "Register"
                |> ProgramTest.expectViewHasNot
                    [ Selector.text "Please enter a valid email address" ]
