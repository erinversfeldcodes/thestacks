module Page.Login exposing
    ( DoorState(..)
    , Mode(..)
    , Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api exposing (AuthResponse)
import Html exposing (Html, button, div, h1, h2, input, label, p, span, text)
import Html.Attributes exposing (class, disabled, for, id, placeholder, type_, value)
import Html.Events exposing (onClick, onInput)
import Http
import Process
import Task
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { email : String
    , password : String
    , displayName : String
    , mode : Mode
    , submitState : RemoteData Http.Error AuthResponse
    , doorState : DoorState
    }


type Mode
    = LoginMode
    | RegisterMode


type DoorState
    = DoorClosed
    | DoorOpening
    | DoorOpen


type Msg
    = EmailChanged String
    | PasswordChanged String
    | DisplayNameChanged String
    | ModeSwitched Mode
    | FormSubmitted
    | GotAuthResponse (Result Http.Error AuthResponse)
    | DoorOpeningStarted AuthResponse
    | DoorFullyOpened AuthResponse


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
    , doorState = DoorClosed
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

        ModeSwitched mode ->
            ( { model | mode = mode, submitState = NotAsked }, Cmd.none, NoOut )

        FormSubmitted ->
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
            ( { model | submitState = Success authResponse }
            , Task.perform (\_ -> DoorOpeningStarted authResponse) (Process.sleep 200)
            , NoOut
            )

        GotAuthResponse (Err err) ->
            ( { model | submitState = Failure err }, Cmd.none, NoOut )

        DoorOpeningStarted authResponse ->
            ( { model | doorState = DoorOpening }
            , Task.perform (\_ -> DoorFullyOpened authResponse) (Process.sleep 1200)
            , NoOut
            )

        DoorFullyOpened authResponse ->
            ( { model | doorState = DoorOpen }
            , Cmd.none
            , LoggedIn authResponse
            )


view : Model -> Html Msg
view model =
    div
        [ class
            ("page page--login"
                ++ doorStateClass model.doorState
            )
        ]
        [ viewDoor model
        ]


doorStateClass : DoorState -> String
doorStateClass doorState =
    case doorState of
        DoorClosed ->
            ""

        DoorOpening ->
            " login-door--opening"

        DoorOpen ->
            " login-door--open"


viewDoor : Model -> Html Msg
viewDoor model =
    div [ class "login-entrance" ]
        [ div [ class "login-door" ]
            [ div [ class "login-door__frame" ]
                [ div [ class "login-door__arch" ] []
                , div [ class "login-door__panel login-door__panel--left" ] []
                , div [ class "login-door__panel login-door__panel--right" ] []
                , div [ class "login-door__handle login-door__handle--left" ] []
                , div [ class "login-door__handle login-door__handle--right" ] []
                ]
            , div [ class "login-door__light" ] []
            ]
        , div [ class "login-form-area" ]
            [ h1 [ class "login-form__heading" ]
                [ text "The Stacks" ]
            , p [ class "login-form__subheading" ]
                [ text
                    (case model.mode of
                        LoginMode ->
                            "Present your credentials to enter"

                        RegisterMode ->
                            "Register for entry to the collection"
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
                        , onClick (ModeSwitched LoginMode)
                        ]
                        [ text "Sign In" ]
                    , button
                        [ class
                            (if model.mode == RegisterMode then
                                "login-form__tab login-form__tab--active"

                             else
                                "login-form__tab"
                            )
                        , onClick (ModeSwitched RegisterMode)
                        ]
                        [ text "Register" ]
                    ]
                , case model.mode of
                    RegisterMode ->
                        div [ class "login-form__field" ]
                            [ label [ class "login-form__label", for "display-name" ]
                                [ text "Display Name" ]
                            , input
                                [ id "display-name"
                                , class "login-form__input"
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
                    [ label [ class "login-form__label", for "email" ]
                        [ text "Email" ]
                    , input
                        [ id "email"
                        , class "login-form__input"
                        , type_ "email"
                        , placeholder "you@example.com"
                        , value model.email
                        , onInput EmailChanged
                        ]
                        []
                    ]
                , div [ class "login-form__field" ]
                    [ label [ class "login-form__label", for "password" ]
                        [ text "Password" ]
                    , input
                        [ id "password"
                        , class "login-form__input"
                        , type_ "password"
                        , placeholder "Enter your password"
                        , value model.password
                        , onInput PasswordChanged
                        ]
                        []
                    ]
                , viewError model
                , button
                    [ class "btn btn--primary login-form__submit"
                    , onClick FormSubmitted
                    , disabled (isSubmitDisabled model)
                    ]
                    [ case model.submitState of
                        Loading ->
                            span [ class "spinner spinner--small" ] []

                        _ ->
                            text
                                (case model.mode of
                                    LoginMode ->
                                        "Enter the Stacks"

                                    RegisterMode ->
                                        "Request Entry"
                                )
                    ]
                ]
            ]
        ]


isSubmitDisabled : Model -> Bool
isSubmitDisabled model =
    model.submitState == Loading || model.doorState /= DoorClosed


viewError : Model -> Html Msg
viewError model =
    case model.submitState of
        Failure err ->
            p [ class "login-form__error" ]
                [ text (errorMessage model.mode err) ]

        _ ->
            text ""


errorMessage : Mode -> Http.Error -> String
errorMessage mode err =
    case err of
        Http.BadStatus 401 ->
            "The door remains shut. Invalid credentials."

        Http.BadStatus 409 ->
            "A reader by that name already frequents these halls."

        Http.BadStatus 422 ->
            "Please ensure all fields are properly filled."

        Http.NetworkError ->
            "The library is unreachable. Please try again."

        Http.Timeout ->
            "The library took too long to respond."

        _ ->
            case mode of
                LoginMode ->
                    "The door remains shut. Invalid email or password."

                RegisterMode ->
                    "Registration could not be completed. The email may already be in use."
