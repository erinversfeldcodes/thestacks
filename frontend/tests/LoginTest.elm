module LoginTest exposing (suite)

import Api exposing (AuthResponse)
import Expect
import Http
import Page.Login as Login exposing (Msg(..))
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
            , test "starts with DoorClosed" <|
                \_ ->
                    Login.init.doorState |> Expect.equal Login.DoorClosed
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
                            , doorState = Login.DoorClosed
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
            [ test "GotAuthResponse Ok sets Success but door stays closed initially" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (GotAuthResponse (Ok fakeAuthResponse)) Login.init
                    in
                    Expect.all
                        [ \m -> m.submitState |> Expect.equal (Success fakeAuthResponse)
                        , \m -> m.doorState |> Expect.equal Login.DoorClosed
                        ]
                        model
            , test "GotAuthResponse Ok does not emit LoggedIn yet (door animation pending)" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            Login.update (GotAuthResponse (Ok fakeAuthResponse)) Login.init
                    in
                    outMsg |> Expect.equal Login.NoOut
            , test "GotAuthResponse Err sets Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (GotAuthResponse (Err Http.NetworkError)) Login.init
                    in
                    model.submitState |> Expect.equal (Failure Http.NetworkError)
            ]
        , describe "door animation"
            [ test "DoorOpeningStarted sets doorState to DoorOpening" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (DoorOpeningStarted fakeAuthResponse) Login.init
                    in
                    model.doorState |> Expect.equal Login.DoorOpening
            , test "DoorFullyOpened sets doorState to DoorOpen and emits LoggedIn" <|
                \_ ->
                    let
                        ( model, _, outMsg ) =
                            Login.update (DoorFullyOpened fakeAuthResponse) Login.init
                    in
                    Expect.all
                        [ \_ -> model.doorState |> Expect.equal Login.DoorOpen
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
        ]
