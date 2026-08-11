module LoginTest exposing (suite)

import Api exposing (AuthResponse, RegisterError(..), RequestError(..))
import Expect
import Http
import Page.Login as Login exposing (FieldValidation(..), Msg(..), SubmitError(..))
import Test exposing (Test, describe, test)
import Types.PasswordRule as PasswordRule
import Types.RemoteData exposing (RemoteData(..))


fakeAuthResponse : AuthResponse
fakeAuthResponse =
    { token = "jwt-token"
    , userId = "user-1"
    , email = "reader@stacks.dev"
    , displayName = "A Reader"
    , handle = "a_reader"
    , role = "user"
    , consentAnalytics = False
    , consentWritingAssistant = False
    }


{-| Build a fully-valid RegisterMode model (email "user@test.com") with the given
password and confirm-password values, driving the real update function so the
validations reflect production behaviour.
-}
registerModelWith : String -> String -> Login.Model
registerModelWith password confirm =
    let
        ( m1, _, _ ) =
            Login.update (ModeSwitched Login.RegisterMode) (Login.init Login.Fresh)

        ( m2, _, _ ) =
            Login.update (EmailChanged "user@test.com") m1

        ( m3, _, _ ) =
            Login.update (DisplayNameChanged "Reader") m2

        ( m4, _, _ ) =
            Login.update (PasswordChanged password) m3

        ( m5, _, _ ) =
            Login.update (PasswordConfirmChanged confirm) m4
    in
    m5


{-| A LoginMode model whose email and password both validate, driven through the
real update function so the field validations match production.
-}
validLoginModel : Login.Model
validLoginModel =
    let
        ( m1, _, _ ) =
            Login.update (EmailChanged "reader@stacks.dev") (Login.init Login.Fresh)

        ( m2, _, _ ) =
            Login.update (PasswordChanged "secret123") m1
    in
    m2


suite : Test
suite =
    describe "Page.Login"
        [ describe "init"
            [ test "starts in LoginMode" <|
                \_ ->
                    (Login.init Login.Fresh).mode |> Expect.equal Login.LoginMode
            , test "starts with NotAsked submit state" <|
                \_ ->
                    (Login.init Login.Fresh).submitState |> Expect.equal NotAsked
            ]
        , describe "field updates"
            [ test "EmailChanged updates email and resets submitState" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (EmailChanged "test@test.com") (Login.init Login.Fresh)
                    in
                    Expect.all
                        [ \m -> m.email |> Expect.equal "test@test.com"
                        , \m -> m.submitState |> Expect.equal NotAsked
                        ]
                        model
            , test "PasswordChanged updates password" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (PasswordChanged "secret") (Login.init Login.Fresh)
                    in
                    model.password |> Expect.equal "secret"
            , test "DisplayNameChanged updates displayName" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (DisplayNameChanged "Reader") (Login.init Login.Fresh)
                    in
                    model.displayName |> Expect.equal "Reader"
            ]
        , describe "mode switching"
            [ test "ModeSwitched to RegisterMode changes mode" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (ModeSwitched Login.RegisterMode) (Login.init Login.Fresh)
                    in
                    model.mode |> Expect.equal Login.RegisterMode
            , test "ModeSwitched resets submitState" <|
                \_ ->
                    let
                        failing =
                            { email = ""
                            , password = ""
                            , displayName = ""
                            , mode = Login.LoginMode
                            , passwordConfirm = ""
                            , submitState = Failure (SubmitHttpError Http.NetworkError)
                            , emailValidation = Pristine
                            , passwordValidation = Pristine
                            , passwordConfirmValidation = Pristine
                            , displayNameValidation = Pristine
                            , arrival = Login.Fresh
                            , forgotState = NotAsked
                            , resendState = NotAsked
                            , inviteCode = ""
                            , inviteCheck = NotAsked
                            , inviteOnly = False
                            }

                        ( model, _, _ ) =
                            Login.update (ModeSwitched Login.RegisterMode) failing
                    in
                    model.submitState |> Expect.equal NotAsked
            ]
        , describe "submit"
            [ test "FormSubmitted sets submitState to Loading" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update FormSubmitted (Login.init Login.Fresh)
                    in
                    model.submitState |> Expect.equal Loading
            , test "FormSubmitted produces NoOut" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            Login.update FormSubmitted (Login.init Login.Fresh)
                    in
                    outMsg |> Expect.equal Login.NoOut
            ]
        , describe "auth response"
            [ test "GotAuthResponse Ok records the response as the submission's outcome" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (GotAuthResponse (Ok fakeAuthResponse)) (Login.init Login.Fresh)
                    in
                    model.submitState |> Expect.equal (Success fakeAuthResponse)
            , test "persist_first: GotAuthResponse Ok hands the credential up on the SAME update" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            Login.update (GotAuthResponse (Ok fakeAuthResponse)) (Login.init Login.Fresh)
                    in
                    outMsg |> Expect.equal (Login.LoggedIn fakeAuthResponse)
            , test "GotAuthResponse Err sets Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (GotAuthResponse (Err (RequestFailed Http.NetworkError))) (Login.init Login.Fresh)
                    in
                    model.submitState |> Expect.equal (Failure (SubmitHttpError Http.NetworkError))
            ]
        , describe "submit lock"
            [ test "a handed-over credential locks the button so a second submit is impossible" <|
                \_ ->
                    let
                        ( succeeded, _, _ ) =
                            Login.update (GotAuthResponse (Ok fakeAuthResponse)) validLoginModel
                    in
                    Login.isSubmitDisabled succeeded |> Expect.equal True
            , test "submit_lock_resets: switching mode after a success unlocks the card" <|
                \_ ->
                    let
                        ( succeeded, _, _ ) =
                            Login.update (GotAuthResponse (Ok fakeAuthResponse)) validLoginModel

                        ( switched, _, _ ) =
                            Login.update (ModeSwitched Login.LoginMode) succeeded

                        ( retyped, _, _ ) =
                            Login.update (EmailChanged "reader@stacks.dev") switched

                        ( ready, _, _ ) =
                            Login.update (PasswordChanged "secret123") retyped
                    in
                    Login.isSubmitDisabled ready |> Expect.equal False
            ]
        , describe "error messages"
            [ test "GotAuthResponse Err BadStatus 401 produces credential error" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (GotAuthResponse (Err (RequestFailed (Http.BadStatus 401)))) (Login.init Login.Fresh)
                    in
                    model.submitState |> Expect.equal (Failure (SubmitHttpError (Http.BadStatus 401)))
            ]
        , describe "validateEmail"
            [ test "empty email is Pristine" <|
                \_ ->
                    Login.validateEmail "" |> Expect.equal Pristine
            , test "valid email is Valid" <|
                \_ ->
                    Login.validateEmail "valid@email.com" |> Expect.equal Valid
            , test "invalid email is Invalid" <|
                \_ ->
                    Login.validateEmail "nope" |> Expect.equal (Invalid "Please enter a valid email address")
            ]
        , describe "validatePassword"
            [ test "empty password is Pristine" <|
                \_ ->
                    Login.validatePassword "" |> Expect.equal Pristine
            , test "valid password is Valid" <|
                \_ ->
                    Login.validatePassword "12345678" |> Expect.equal Valid
            , test "short password is Invalid" <|
                \_ ->
                    Login.validatePassword "short" |> Expect.equal (Invalid PasswordRule.tooShort)
            ]
        , describe "validateDisplayName"
            [ test "empty display name is Pristine" <|
                \_ ->
                    Login.validateDisplayName "" |> Expect.equal Pristine
            , test "non-empty display name is Valid" <|
                \_ ->
                    Login.validateDisplayName "Name" |> Expect.equal Valid
            ]
        , describe "validation wiring"
            [ test "EmailChanged with invalid email sets emailValidation to Invalid" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (EmailChanged "nope") (Login.init Login.Fresh)
                    in
                    model.emailValidation |> Expect.equal (Invalid "Please enter a valid email address")
            , test "submit is disabled when email is Invalid" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (EmailChanged "nope") (Login.init Login.Fresh)
                    in
                    Login.isSubmitDisabled model |> Expect.equal True
            , test "submit is disabled when all fields are Pristine" <|
                \_ ->
                    Login.isSubmitDisabled (Login.init Login.Fresh) |> Expect.equal True
            , test "submit is enabled when email and password are Valid in LoginMode" <|
                \_ ->
                    let
                        ( m1, _, _ ) =
                            Login.update (EmailChanged "user@test.com") (Login.init Login.Fresh)

                        ( m2, _, _ ) =
                            Login.update (PasswordChanged "longpassword") m1
                    in
                    Login.isSubmitDisabled m2 |> Expect.equal False
            , test "submit is disabled in RegisterMode when displayName is Pristine" <|
                \_ ->
                    let
                        ( m1, _, _ ) =
                            Login.update (ModeSwitched Login.RegisterMode) (Login.init Login.Fresh)

                        ( m2, _, _ ) =
                            Login.update (EmailChanged "user@test.com") m1

                        ( m3, _, _ ) =
                            Login.update (PasswordChanged "longpassword") m2
                    in
                    Login.isSubmitDisabled m3 |> Expect.equal True
            ]
        , describe "validatePasswordConfirm"
            [ test "empty confirm is Pristine" <|
                \_ ->
                    Login.validatePasswordConfirm "secret123" "" |> Expect.equal Pristine
            , test "matching confirm is Valid" <|
                \_ ->
                    Login.validatePasswordConfirm "secret123" "secret123" |> Expect.equal Valid
            , test "mismatched confirm is Invalid" <|
                \_ ->
                    Login.validatePasswordConfirm "secret123" "different"
                        |> Expect.equal (Invalid "Passwords do not match")
            ]
        , describe "password confirm wiring"
            [ test "PasswordConfirmChanged updates passwordConfirm and validates against current password" <|
                \_ ->
                    let
                        ( m1, _, _ ) =
                            Login.update (PasswordChanged "longpassword") (Login.init Login.Fresh)

                        ( m2, _, _ ) =
                            Login.update (PasswordConfirmChanged "longpassword") m1
                    in
                    Expect.all
                        [ \m -> m.passwordConfirm |> Expect.equal "longpassword"
                        , \m -> m.passwordConfirmValidation |> Expect.equal Valid
                        ]
                        m2
            , test "mismatched confirm password disables submit in RegisterMode" <|
                \_ ->
                    Login.isSubmitDisabled (registerModelWith "longpassword" "different")
                        |> Expect.equal True
            , test "matching confirm password enables submit in RegisterMode" <|
                \_ ->
                    Login.isSubmitDisabled (registerModelWith "longpassword" "longpassword")
                        |> Expect.equal False
            , test "pristine confirm password disables submit in RegisterMode" <|
                \_ ->
                    Login.isSubmitDisabled (registerModelWith "longpassword" "")
                        |> Expect.equal True
            ]
        , describe "registration response"
            [ test "GotRegisterResponse Ok switches to RegistrationPending carrying the email" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (GotRegisterResponse (Ok ()))
                                (registerModelWith "longpassword" "longpassword")
                    in
                    model.mode |> Expect.equal (Login.RegistrationPending "user@test.com")
            , test "GotRegisterResponse Ok emits RegistrationSucceeded carrying the email and does NOT start the door transition" <|
                \_ ->
                    let
                        ( model, _, outMsg ) =
                            Login.update (GotRegisterResponse (Ok ()))
                                (registerModelWith "longpassword" "longpassword")

                        succeededEmail =
                            case outMsg of
                                Login.RegistrationSucceeded email ->
                                    Just email

                                _ ->
                                    Nothing
                    in
                    Expect.all
                        [ \_ -> succeededEmail |> Expect.equal (Just "user@test.com")
                        , \_ -> model.submitState |> Expect.equal NotAsked
                        ]
                        ()
            , test "GotRegisterResponse Ok does not store a Success auth response (no blank JWT)" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (GotRegisterResponse (Ok ()))
                                (registerModelWith "longpassword" "longpassword")
                    in
                    model.submitState |> Expect.equal NotAsked
            , test "GotRegisterResponse Err (RegisterRequestFailed ...) sets Failure with the wrapped Http error" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (GotRegisterResponse (Err (RegisterRequestFailed (Http.BadStatus 422))))
                                (registerModelWith "longpassword" "longpassword")
                    in
                    model.submitState |> Expect.equal (Failure (SubmitHttpError (Http.BadStatus 422)))
            , test "GotRegisterResponse Err (RegisterValidationFailed ...) stores the field errors" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update
                                (GotRegisterResponse (Err (RegisterValidationFailed [ ( "password", [ "must be at least 8 characters" ] ) ])))
                                (registerModelWith "longpassword" "longpassword")
                    in
                    model.submitState
                        |> Expect.equal (Failure (SubmitValidationError [ ( "password", [ "must be at least 8 characters" ] ) ]))
            ]
        , describe "errorMessage for registration validation"
            [ test "a password validation error surfaces the password message" <|
                \_ ->
                    Login.errorMessage Login.RegisterMode
                        (SubmitValidationError [ ( "password", [ "must be at least 8 characters" ] ) ])
                        |> Expect.equal PasswordRule.tooShort
            , test "a password validation error is NOT the email-in-use copy" <|
                \_ ->
                    Login.errorMessage Login.RegisterMode
                        (SubmitValidationError [ ( "password", [ "must be at least 8 characters" ] ) ])
                        |> Expect.notEqual "A reader with that email already frequents these halls. Try signing in instead."
            , test "a duplicate-email validation error surfaces the email-in-use message" <|
                \_ ->
                    Login.errorMessage Login.RegisterMode
                        (SubmitValidationError [ ( "email", [ "has already been taken" ] ) ])
                        |> Expect.equal "A reader with that email already frequents these halls. Try signing in instead."
            , test "403 message is unchanged" <|
                \_ ->
                    Login.errorMessage Login.LoginMode (SubmitHttpError (Http.BadStatus 403))
                        |> Expect.equal "Please confirm your email address before signing in. Check your inbox for the confirmation email."
            , test "423 message is unchanged" <|
                \_ ->
                    Login.errorMessage Login.LoginMode (SubmitHttpError (Http.BadStatus 423))
                        |> Expect.equal "This account is temporarily locked after too many failed attempts. Please try again in a little while."
            , test "503 message is unchanged" <|
                \_ ->
                    Login.errorMessage Login.LoginMode (SubmitHttpError (Http.BadStatus 503))
                        |> Expect.equal "The library is briefly overloaded. Please try again in a few seconds."
            ]
        , unknownStatusClaimsNothing
        , throttledSignInSuite
        , forgotPasswordModeSuite
        ]


{-| ⛔ Failure copy may only claim what the status proves. The catch-all
said "Invalid email or password" for every unlisted status, so a
mid-deploy 502 told the reader their correct credentials were wrong.
Only 401 blames credentials; unknown statuses get honest retry copy.
-}
unknownStatusClaimsNothing : Test
unknownStatusClaimsNothing =
    describe "an unknown failure never claims a known cause"
        [ test "a 502 does not tell the reader their credentials are wrong" <|
            \_ ->
                Login.errorMessage Login.LoginMode (SubmitHttpError (Http.BadStatus 502))
                    |> Expect.notEqual "The door remains shut. Invalid email or password."
        , test "a 502 says so is the library's fault, not the reader's" <|
            \_ ->
                Login.errorMessage Login.LoginMode (SubmitHttpError (Http.BadStatus 502))
                    |> Expect.equal "The library is having trouble at its own end. Nothing is wrong with what you entered — please try again in a moment."
        , test "a status nobody anticipated admits it is not understood" <|
            \_ ->
                Login.errorMessage Login.LoginMode (SubmitHttpError (Http.BadStatus 418))
                    |> String.contains "we cannot say why"
                    |> Expect.equal True
        , test "a status nobody anticipated is not reported as a bad credential" <|
            \_ ->
                Login.errorMessage Login.LoginMode (SubmitHttpError (Http.BadStatus 418))
                    |> Expect.notEqual "The door remains shut. Invalid email or password."
        , test "registration does not guess 'the email may already be in use' either" <|
            \_ ->
                Login.errorMessage Login.RegisterMode (SubmitHttpError (Http.BadStatus 418))
                    |> Expect.notEqual "Registration could not be completed. The email may already be in use."
        , test "positive control — a 401 still says the credentials are wrong" <|
            \_ ->
                Login.errorMessage Login.LoginMode (SubmitHttpError (Http.BadStatus 401))
                    |> Expect.equal "The door remains shut. Invalid credentials."
        ]


{-| The 429, with the wait the server named (requirement 3).

Consistency with the 423 lockout copy asserted directly: both end in an
instruction to wait, and neither invents an interval it was not given.

-}
throttledSignInSuite : Test
throttledSignInSuite =
    describe "a throttled sign-in"
        [ test "a 429 with retry-after names the wait" <|
            \_ ->
                Login.errorMessage Login.LoginMode (SubmitRateLimited (Just 60))
                    |> Expect.equal "Too many attempts from here just now. Please wait a minute before trying again."
        , test "a 429 without one names no wait at all" <|
            \_ ->
                Login.errorMessage Login.LoginMode (SubmitRateLimited Nothing)
                    |> Expect.equal "Too many attempts from here just now. Please wait a little while before trying again."
        , test "a throttle is never reported as a bad credential" <|
            \_ ->
                Login.errorMessage Login.LoginMode (SubmitRateLimited Nothing)
                    |> Expect.notEqual "The door remains shut. Invalid email or password."
        , test "a 429 response is classified as a throttle, carrying its retry-after" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        Login.update
                            (GotAuthResponse (Err (RateLimited (Just 90))))
                            (Login.init Login.Fresh)
                in
                model.submitState |> Expect.equal (Failure (SubmitRateLimited (Just 90)))
        ]


forgotPasswordModeSuite : Test
forgotPasswordModeSuite =
    describe "forgot-password mode (in the login card)"
        [ test "switching to ForgotPasswordMode sets the mode" <|
            \_ ->
                let
                    ( m, _, _ ) =
                        Login.update (ModeSwitched Login.ForgotPasswordMode) (Login.init Login.Fresh)
                in
                m.mode |> Expect.equal Login.ForgotPasswordMode
        , test "ForgotSubmitted with an email moves forgotState to Loading" <|
            \_ ->
                let
                    ( m1, _, _ ) =
                        Login.update (EmailChanged "reader@test.com") (Login.init Login.Fresh)

                    ( m2, _, _ ) =
                        Login.update ForgotSubmitted m1
                in
                m2.forgotState |> Expect.equal Loading
        , test "ForgotSubmitted with a blank email is a no-op" <|
            \_ ->
                let
                    ( m, _, _ ) =
                        Login.update ForgotSubmitted (Login.init Login.Fresh)
                in
                m.forgotState |> Expect.equal NotAsked
        , test "a successful forgot response shows Success" <|
            \_ ->
                let
                    ( m1, _, _ ) =
                        Login.update (EmailChanged "reader@test.com") (Login.init Login.Fresh)

                    ( m2, _, _ ) =
                        Login.update ForgotSubmitted m1

                    ( m3, _, _ ) =
                        Login.update (GotForgotResponse (Ok ())) m2
                in
                m3.forgotState |> Expect.equal (Success ())
        , test "a failed forgot response shows Failure" <|
            \_ ->
                let
                    ( m1, _, _ ) =
                        Login.update (EmailChanged "reader@test.com") (Login.init Login.Fresh)

                    ( m2, _, _ ) =
                        Login.update ForgotSubmitted m1

                    ( m3, _, _ ) =
                        Login.update (GotForgotResponse (Err (RequestFailed Http.NetworkError))) m2
                in
                m3.forgotState |> Expect.equal (Failure (RequestFailed Http.NetworkError))
        ]
