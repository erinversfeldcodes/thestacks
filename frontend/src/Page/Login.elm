module Page.Login exposing
    ( FieldValidation(..)
    , Mode(..)
    , Model
    , Msg(..)
    , OutMsg(..)
    , TransitionState(..)
    , init
    , isSubmitDisabled
    , update
    , validateDisplayName
    , validateEmail
    , validatePassword
    , view
    )

import Api exposing (AuthResponse)
import Html exposing (Html, button, div, h1, input, label, p, span, text)
import Html.Attributes exposing (attribute, class, disabled, for, id, placeholder, type_, value)
import Html.Events exposing (onClick, onInput)
import Http
import Types.RemoteData exposing (RemoteData(..))


type FieldValidation
    = Pristine
    | Valid
    | Invalid String


type alias Model =
    { email : String
    , password : String
    , displayName : String
    , mode : Mode
    , submitState : RemoteData Http.Error AuthResponse
    , transitionState : TransitionState
    , emailValidation : FieldValidation
    , passwordValidation : FieldValidation
    , displayNameValidation : FieldValidation
    }


type Mode
    = LoginMode
    | RegisterMode


type TransitionState
    = Idle
    | Transitioning
    | Complete


type Msg
    = EmailChanged String
    | PasswordChanged String
    | DisplayNameChanged String
    | ModeSwitched Mode
    | FormSubmitted
    | GotAuthResponse (Result Http.Error AuthResponse)
    | TransitionCompleted AuthResponse


type OutMsg
    = NoOut
    | StartTransition AuthResponse
    | LoggedIn AuthResponse


init : Model
init =
    { email = ""
    , password = ""
    , displayName = ""
    , mode = LoginMode
    , submitState = NotAsked
    , transitionState = Idle
    , emailValidation = Pristine
    , passwordValidation = Pristine
    , displayNameValidation = Pristine
    }


validateEmail : String -> FieldValidation
validateEmail email =
    if String.isEmpty email then
        Pristine

    else if String.contains "@" email && String.contains "." email then
        Valid

    else
        Invalid "Please enter a valid email address"


validatePassword : String -> FieldValidation
validatePassword password =
    if String.isEmpty password then
        Pristine

    else if String.length password >= 8 then
        Valid

    else
        Invalid "Password must be at least 8 characters"


validateDisplayName : String -> FieldValidation
validateDisplayName name =
    if String.isEmpty name then
        Pristine

    else
        Valid


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        EmailChanged email ->
            ( { model | email = email, submitState = NotAsked, emailValidation = validateEmail email }, Cmd.none, NoOut )

        PasswordChanged password ->
            ( { model | password = password, submitState = NotAsked, passwordValidation = validatePassword password }, Cmd.none, NoOut )

        DisplayNameChanged name ->
            ( { model | displayName = name, submitState = NotAsked, displayNameValidation = validateDisplayName name }, Cmd.none, NoOut )

        ModeSwitched mode ->
            ( { model | mode = mode, submitState = NotAsked, emailValidation = Pristine, passwordValidation = Pristine, displayNameValidation = Pristine }, Cmd.none, NoOut )

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
            ( { model | submitState = Success authResponse, transitionState = Transitioning }
            , Cmd.none
            , StartTransition authResponse
            )

        GotAuthResponse (Err err) ->
            ( { model | submitState = Failure err }, Cmd.none, NoOut )

        TransitionCompleted authResponse ->
            ( { model | transitionState = Complete }
            , Cmd.none
            , LoggedIn authResponse
            )


view : Model -> Html Msg
view model =
    div [ class "page page--login" ]
        [ div [ class "layer-arrival" ] []
        , div [ class "layer-passage", id "passage" ] []
        , div [ class "layer-passage-bright", id "passageBright" ] []
        , div [ class "layer-bookshelf", id "bookshelf" ] []
        , div [ class "layer-bookshelf-dim", id "bookshelfDim" ] []
        , div [ class "layer-vignette", id "vignette" ] []
        , div [ class "layer-wash", id "wash" ] []
        , div [ class "login-overlay", id "overlay" ]
            [ viewLoginCard model ]
        ]


viewLoginCard : Model -> Html Msg
viewLoginCard model =
    div [ class "login-card" ]
        [ h1 [ class "login-card__title" ] [ text "The Stacks" ]
        , p [ class "login-card__subtitle" ]
            [ text
                (case model.mode of
                    LoginMode ->
                        "Present your credentials to enter"

                    RegisterMode ->
                        "Register for entry to the collection"
                )
            ]
        , div
            [ class "login-card__tabs"
            , attribute "role" "tablist"
            ]
            [ button
                [ class
                    (if model.mode == LoginMode then
                        "login-card__tab login-card__tab--active"

                     else
                        "login-card__tab"
                    )
                , attribute "role" "tab"
                , attribute "aria-selected"
                    (if model.mode == LoginMode then
                        "true"

                     else
                        "false"
                    )
                , onClick (ModeSwitched LoginMode)
                ]
                [ text "Sign In" ]
            , button
                [ class
                    (if model.mode == RegisterMode then
                        "login-card__tab login-card__tab--active"

                     else
                        "login-card__tab"
                    )
                , attribute "role" "tab"
                , attribute "aria-selected"
                    (if model.mode == RegisterMode then
                        "true"

                     else
                        "false"
                    )
                , onClick (ModeSwitched RegisterMode)
                ]
                [ text "Register" ]
            ]
        , case model.mode of
            RegisterMode ->
                div [ class (fieldClass model.displayNameValidation) ]
                    [ label [ class "login-card__label", for "display-name" ]
                        [ text "Display Name" ]
                    , input
                        [ id "display-name"
                        , class "login-card__input"
                        , type_ "text"
                        , placeholder "Your name"
                        , value model.displayName
                        , onInput DisplayNameChanged
                        ]
                        []
                    , viewFieldHint model.displayNameValidation
                    ]

            LoginMode ->
                text ""
        , div [ class (fieldClass model.emailValidation) ]
            [ label [ class "login-card__label", for "email" ]
                [ text "Email" ]
            , input
                [ id "email"
                , class "login-card__input"
                , type_ "email"
                , placeholder "you@example.com"
                , value model.email
                , onInput EmailChanged
                , attribute "aria-required" "true"
                ]
                []
            , viewFieldHint model.emailValidation
            ]
        , div [ class (fieldClass model.passwordValidation) ]
            [ label [ class "login-card__label", for "password" ]
                [ text "Password" ]
            , input
                [ id "password"
                , class "login-card__input"
                , type_ "password"
                , placeholder "Enter your password"
                , value model.password
                , onInput PasswordChanged
                , attribute "aria-required" "true"
                ]
                []
            , viewFieldHint model.passwordValidation
            ]
        , viewError model
        , button
            [ class "login-card__submit"
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


isSubmitDisabled : Model -> Bool
isSubmitDisabled model =
    let
        isInvalidOrPristine validation =
            case validation of
                Valid ->
                    False

                _ ->
                    True

        fieldsInvalid =
            case model.mode of
                LoginMode ->
                    isInvalidOrPristine model.emailValidation
                        || isInvalidOrPristine model.passwordValidation

                RegisterMode ->
                    isInvalidOrPristine model.emailValidation
                        || isInvalidOrPristine model.passwordValidation
                        || isInvalidOrPristine model.displayNameValidation
    in
    model.submitState == Loading || model.transitionState /= Idle || fieldsInvalid


fieldClass : FieldValidation -> String
fieldClass validation =
    case validation of
        Pristine ->
            "login-card__field"

        Valid ->
            "login-card__field login-card__field--valid"

        Invalid _ ->
            "login-card__field login-card__field--error"


viewFieldHint : FieldValidation -> Html Msg
viewFieldHint validation =
    case validation of
        Invalid msg ->
            div [ class "login-card__hint login-card__hint--error" ] [ text msg ]

        Valid ->
            div [ class "login-card__hint login-card__hint--valid" ] [ text "Looks good" ]

        Pristine ->
            text ""


viewError : Model -> Html Msg
viewError model =
    case model.submitState of
        Failure err ->
            div [ attribute "aria-live" "polite" ]
                [ p [ class "login-card__error" ]
                    [ text (errorMessage model.mode err) ]
                ]

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
