module LoginTest exposing (suite)

import Api exposing (AuthResponse)
import Expect
import Http
import Page.Login as Login exposing (FieldValidation(..), Msg(..))
import Test exposing (Test, describe, test)
import Types.RemoteData exposing (RemoteData(..))


fakeAuthResponse : AuthResponse
fakeAuthResponse =
    { token = "jwt-token"
    , userId = "user-1"
    , email = "reader@stacks.dev"
    , displayName = "A Reader"
    }


suite : Test
suite =
    describe "Page.Login"
        [ describe "init"
            [ test "starts in LoginMode" <|
                \_ ->
                    Login.init.mode |> Expect.equal Login.LoginMode
            , test "starts with Idle transition state" <|
                \_ ->
                    Login.init.transitionState |> Expect.equal Login.Idle
            , test "starts with NotAsked submit state" <|
                \_ ->
                    Login.init.submitState |> Expect.equal NotAsked
            ]
        , describe "field updates"
            [ test "EmailChanged updates email and resets submitState" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (EmailChanged "test@test.com") Login.init
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
                            Login.update (PasswordChanged "secret") Login.init
                    in
                    model.password |> Expect.equal "secret"
            , test "DisplayNameChanged updates displayName" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (DisplayNameChanged "Reader") Login.init
                    in
                    model.displayName |> Expect.equal "Reader"
            ]
        , describe "mode switching"
            [ test "ModeSwitched to RegisterMode changes mode" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (ModeSwitched Login.RegisterMode) Login.init
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
                            , submitState = Failure Http.NetworkError
                            , transitionState = Login.Idle
                            , emailValidation = Pristine
                            , passwordValidation = Pristine
                            , displayNameValidation = Pristine
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
                            Login.update FormSubmitted Login.init
                    in
                    model.submitState |> Expect.equal Loading
            , test "FormSubmitted produces NoOut" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            Login.update FormSubmitted Login.init
                    in
                    outMsg |> Expect.equal Login.NoOut
            ]
        , describe "auth response"
            [ test "GotAuthResponse Ok sets Success and transitions to Transitioning" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (GotAuthResponse (Ok fakeAuthResponse)) Login.init
                    in
                    Expect.all
                        [ \m -> m.submitState |> Expect.equal (Success fakeAuthResponse)
                        , \m -> m.transitionState |> Expect.equal Login.Transitioning
                        ]
                        model
            , test "GotAuthResponse Ok emits StartTransition (not LoggedIn yet)" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            Login.update (GotAuthResponse (Ok fakeAuthResponse)) Login.init
                    in
                    outMsg |> Expect.equal (Login.StartTransition fakeAuthResponse)
            , test "GotAuthResponse Err sets Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (GotAuthResponse (Err Http.NetworkError)) Login.init
                    in
                    model.submitState |> Expect.equal (Failure Http.NetworkError)
            ]
        , describe "transition completion"
            [ test "TransitionCompleted sets transitionState to Complete and emits LoggedIn" <|
                \_ ->
                    let
                        ( model, _, outMsg ) =
                            Login.update (TransitionCompleted fakeAuthResponse) Login.init
                    in
                    Expect.all
                        [ \_ -> model.transitionState |> Expect.equal Login.Complete
                        , \_ -> outMsg |> Expect.equal (Login.LoggedIn fakeAuthResponse)
                        ]
                        ()
            ]
        , describe "error messages"
            [ test "GotAuthResponse Err BadStatus 401 produces credential error" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (GotAuthResponse (Err (Http.BadStatus 401))) Login.init
                    in
                    model.submitState |> Expect.equal (Failure (Http.BadStatus 401))
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
                    Login.validatePassword "short" |> Expect.equal (Invalid "Password must be at least 8 characters")
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
                            Login.update (EmailChanged "nope") Login.init
                    in
                    model.emailValidation |> Expect.equal (Invalid "Please enter a valid email address")
            , test "submit is disabled when email is Invalid" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (EmailChanged "nope") Login.init
                    in
                    Login.isSubmitDisabled model |> Expect.equal True
            , test "submit is disabled when all fields are Pristine" <|
                \_ ->
                    Login.isSubmitDisabled Login.init |> Expect.equal True
            , test "submit is enabled when email and password are Valid in LoginMode" <|
                \_ ->
                    let
                        ( m1, _, _ ) =
                            Login.update (EmailChanged "user@test.com") Login.init

                        ( m2, _, _ ) =
                            Login.update (PasswordChanged "longpassword") m1
                    in
                    Login.isSubmitDisabled m2 |> Expect.equal False
            , test "submit is disabled in RegisterMode when displayName is Pristine" <|
                \_ ->
                    let
                        ( m1, _, _ ) =
                            Login.update (ModeSwitched Login.RegisterMode) Login.init

                        ( m2, _, _ ) =
                            Login.update (EmailChanged "user@test.com") m1

                        ( m3, _, _ ) =
                            Login.update (PasswordChanged "longpassword") m2
                    in
                    Login.isSubmitDisabled m3 |> Expect.equal True
            ]
        ]
