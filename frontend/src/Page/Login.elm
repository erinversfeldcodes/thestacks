module Page.Login exposing
    ( Model
    , Msg
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api exposing (AuthResponse)
import Html exposing (Html, button, div, h1, input, label, p, span, text)
import Html.Attributes exposing (class, disabled, for, id, placeholder, type_, value)
import Html.Events exposing (onClick, onInput)
import Http
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { email : String
    , password : String
    , displayName : String
    , mode : Mode
    , submitState : RemoteData Http.Error AuthResponse
    }


type Mode
    = LoginMode
    | RegisterMode


type Msg
    = EmailChanged String
    | PasswordChanged String
    | DisplayNameChanged String
    | SwitchMode Mode
    | Submit
    | GotAuthResponse (Result Http.Error AuthResponse)


type OutMsg
    = NoOut
    | LoggedIn AuthResponse


init : Model
init =
    { email = ""
    , password = ""
    , displayName = ""
    , mode = LoginMode
    , submitState = NotAsked
    }


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        EmailChanged email ->
            ( { model | email = email, submitState = NotAsked }, Cmd.none, NoOut )

        PasswordChanged password ->
            ( { model | password = password, submitState = NotAsked }, Cmd.none, NoOut )

        DisplayNameChanged name ->
            ( { model | displayName = name, submitState = NotAsked }, Cmd.none, NoOut )

        SwitchMode mode ->
            ( { model | mode = mode, submitState = NotAsked }, Cmd.none, NoOut )

        Submit ->
            let
                cmd =
                    case model.mode of
                        LoginMode ->
                            Api.login
                                { email = model.email, password = model.password }
                                GotAuthResponse

                        RegisterMode ->
                            Api.register
                                { email = model.email
                                , password = model.password
                                , displayName = model.displayName
                                }
                                GotAuthResponse
            in
            ( { model | submitState = Loading }, cmd, NoOut )

        GotAuthResponse (Ok authResponse) ->
            ( { model | submitState = Success authResponse }, Cmd.none, LoggedIn authResponse )

        GotAuthResponse (Err err) ->
            ( { model | submitState = Failure err }, Cmd.none, NoOut )


view : Model -> Html Msg
view model =
    div [ class "page page--login" ]
        [ h1 [ class "page__title" ]
            [ text
                (case model.mode of
                    LoginMode ->
                        "Sign In"

                    RegisterMode ->
                        "Create Account"
                )
            ]
        , div [ class "login-form" ]
            [ div [ class "login-form__tabs" ]
                [ button
                    [ class
                        (if model.mode == LoginMode then
                            "login-form__tab login-form__tab--active"

                         else
                            "login-form__tab"
                        )
                    , onClick (SwitchMode LoginMode)
                    ]
                    [ text "Sign In" ]
                , button
                    [ class
                        (if model.mode == RegisterMode then
                            "login-form__tab login-form__tab--active"

                         else
                            "login-form__tab"
                        )
                    , onClick (SwitchMode RegisterMode)
                    ]
                    [ text "Register" ]
                ]
            , case model.mode of
                RegisterMode ->
                    div [ class "login-form__field" ]
                        [ label [ for "display-name" ] [ text "Display Name" ]
                        , input
                            [ id "display-name"
                            , type_ "text"
                            , placeholder "Your name"
                            , value model.displayName
                            , onInput DisplayNameChanged
                            ]
                            []
                        ]

                LoginMode ->
                    text ""
            , div [ class "login-form__field" ]
                [ label [ for "email" ] [ text "Email" ]
                , input
                    [ id "email"
                    , type_ "email"
                    , placeholder "you@example.com"
                    , value model.email
                    , onInput EmailChanged
                    ]
                    []
                ]
            , div [ class "login-form__field" ]
                [ label [ for "password" ] [ text "Password" ]
                , input
                    [ id "password"
                    , type_ "password"
                    , placeholder "••••••••"
                    , value model.password
                    , onInput PasswordChanged
                    ]
                    []
                ]
            , case model.submitState of
                Failure _ ->
                    p [ class "login-form__error" ]
                        [ text
                            (case model.mode of
                                LoginMode ->
                                    "Invalid email or password."

                                RegisterMode ->
                                    "Registration failed. Email may already be in use."
                            )
                        ]

                _ ->
                    text ""
            , button
                [ class "btn btn--primary login-form__submit"
                , onClick Submit
                , disabled (model.submitState == Loading)
                ]
                [ case model.submitState of
                    Loading ->
                        span [ class "spinner spinner--small" ] []

                    _ ->
                        text
                            (case model.mode of
                                LoginMode ->
                                    "Sign In"

                                RegisterMode ->
                                    "Create Account"
                            )
                ]
            ]
        ]
