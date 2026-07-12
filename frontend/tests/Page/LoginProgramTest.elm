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
import TestHelpers exposing (loginProgram, simulateAuthErrorResponse, simulateAuthResponse, simulateRegisterResponse, simulateRegisterValidationResponse)


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
        , registerHappyShowsPending
        , registerPendingNamesEmail
        , registerMismatchDisablesSubmit
        , registerDuplicateEmailShowsMessage
        , registerValidationEmailShowsMessage
        , registerWeakPasswordShowsPasswordMessage
        , backToSignInResetsToLogin
        , login403ShowsConfirmEmailMessage
        , login423ShowsAccountLockedMessage
        , login503ShowsServiceBusyMessage
        ]


{-| Fill in every register field with valid, matching values and submit.
-}
fillRegisterFormAndSubmit : ProgramTest.ProgramTest Login.Model Login.Msg (ProgramTest.SimulatedEffect Login.Msg) -> ProgramTest.ProgramTest Login.Model Login.Msg (ProgramTest.SimulatedEffect Login.Msg)
fillRegisterFormAndSubmit program =
    program
        |> ProgramTest.clickButton "Register"
        |> ProgramTest.fillIn "display-name" "Display Name" "New Reader"
        |> ProgramTest.fillIn "email" "Email" "new@stacks.dev"
        |> ProgramTest.fillIn "password" "Password" "secret123"
        |> ProgramTest.fillIn "password-confirm" "Confirm Password" "secret123"
        |> ProgramTest.clickButton "Request Entry"


registerHappyShowsPending : Test
registerHappyShowsPending =
    test "register_happy_shows_pending: successful registration shows the check-inbox card, not a login" <|
        \() ->
            startLogin
                |> fillRegisterFormAndSubmit
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/auth/register"
                    simulateRegisterResponse
                |> ProgramTest.ensureViewHas [ Selector.text "Check your inbox!" ]
                |> ProgramTest.expectViewHasNot [ Selector.text "Request Entry" ]


registerPendingNamesEmail : Test
registerPendingNamesEmail =
    test "register_pending_names_email: pending card names the registered email address" <|
        \() ->
            startLogin
                |> fillRegisterFormAndSubmit
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/auth/register"
                    simulateRegisterResponse
                |> ProgramTest.expectViewHas [ Selector.text "new@stacks.dev" ]


registerMismatchDisablesSubmit : Test
registerMismatchDisablesSubmit =
    test "register_mismatch_disables_submit: mismatched confirm shows hint and disables submit" <|
        \() ->
            startLogin
                |> ProgramTest.clickButton "Register"
                |> ProgramTest.fillIn "display-name" "Display Name" "New Reader"
                |> ProgramTest.fillIn "email" "Email" "new@stacks.dev"
                |> ProgramTest.fillIn "password" "Password" "secret123"
                |> ProgramTest.fillIn "password-confirm" "Confirm Password" "different"
                |> ProgramTest.ensureViewHas [ Selector.text "Passwords do not match" ]
                |> ProgramTest.expectViewHas
                    [ Selector.class "login-card__submit"
                    , Selector.disabled True
                    ]


registerDuplicateEmailShowsMessage : Test
registerDuplicateEmailShowsMessage =
    test "register_duplicate_email_shows_message: 422 on register shows the email-in-use message" <|
        \() ->
            startLogin
                |> fillRegisterFormAndSubmit
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/auth/register"
                    (simulateAuthErrorResponse 422)
                |> ProgramTest.expectViewHas
                    [ Selector.text "A reader with that email already frequents these halls. Try signing in instead." ]


registerValidationEmailShowsMessage : Test
registerValidationEmailShowsMessage =
    test "register_validation_email_shows_message: a 422 with a duplicate-email error shows the email-in-use message" <|
        \() ->
            startLogin
                |> fillRegisterFormAndSubmit
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/auth/register"
                    (simulateRegisterValidationResponse [ ( "email", [ "has already been taken" ] ) ])
                |> ProgramTest.ensureViewHas
                    [ Selector.text "A reader with that email already frequents these halls. Try signing in instead." ]
                |> ProgramTest.expectViewHasNot
                    [ Selector.text "That password is too slight; please choose at least eight characters." ]


registerWeakPasswordShowsPasswordMessage : Test
registerWeakPasswordShowsPasswordMessage =
    test "register_weak_password_shows_password_message: a 422 with a password error shows a password message, not the email-in-use copy" <|
        \() ->
            startLogin
                |> fillRegisterFormAndSubmit
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/auth/register"
                    (simulateRegisterValidationResponse [ ( "password", [ "must be at least 8 characters" ] ) ])
                |> ProgramTest.ensureViewHas
                    [ Selector.text "That password is too slight; please choose at least eight characters." ]
                |> ProgramTest.expectViewHasNot
                    [ Selector.text "A reader with that email already frequents these halls. Try signing in instead." ]


backToSignInResetsToLogin : Test
backToSignInResetsToLogin =
    test "back_to_sign_in_resets_to_login: pending card 'Back to Sign In' returns to the login form" <|
        \() ->
            startLogin
                |> fillRegisterFormAndSubmit
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/auth/register"
                    simulateRegisterResponse
                |> ProgramTest.ensureViewHas [ Selector.text "Check your inbox!" ]
                |> ProgramTest.clickButton "Back to Sign In"
                |> ProgramTest.expectViewHas [ Selector.text "Present your credentials to enter" ]


login403ShowsConfirmEmailMessage : Test
login403ShowsConfirmEmailMessage =
    test "login_403_shows_confirm_email_message: unconfirmed-email login shows the confirm-email guidance" <|
        \() ->
            startLogin
                |> ProgramTest.fillIn "email" "Email" "reader@stacks.dev"
                |> ProgramTest.fillIn "password" "Password" "secret123"
                |> ProgramTest.clickButton "Enter the Stacks"
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/auth/login"
                    (simulateAuthErrorResponse 403)
                |> ProgramTest.expectViewHas
                    [ Selector.text "Please confirm your email address before signing in. Check your inbox for the confirmation email." ]


login423ShowsAccountLockedMessage : Test
login423ShowsAccountLockedMessage =
    test "login_423_shows_account_locked_message: locked account shows a lockout message, not invalid credentials" <|
        \() ->
            startLogin
                |> ProgramTest.fillIn "email" "Email" "reader@stacks.dev"
                |> ProgramTest.fillIn "password" "Password" "secret123"
                |> ProgramTest.clickButton "Enter the Stacks"
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/auth/login"
                    (simulateAuthErrorResponse 423)
                |> ProgramTest.expectViewHas
                    [ Selector.text "This account is temporarily locked after too many failed attempts. Please try again in a little while." ]


login503ShowsServiceBusyMessage : Test
login503ShowsServiceBusyMessage =
    test "login_503_shows_service_busy_message: overloaded auth service shows a try-again-shortly message" <|
        \() ->
            startLogin
                |> ProgramTest.fillIn "email" "Email" "reader@stacks.dev"
                |> ProgramTest.fillIn "password" "Password" "secret123"
                |> ProgramTest.clickButton "Enter the Stacks"
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/auth/login"
                    (simulateAuthErrorResponse 503)
                |> ProgramTest.expectViewHas
                    [ Selector.text "The library is briefly overloaded. Please try again in a few seconds." ]


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
