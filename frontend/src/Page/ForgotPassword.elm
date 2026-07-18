module Page.ForgotPassword exposing
    ( Model
    , Msg(..)
    , init
    , update
    , view
    )

import Api
import Html exposing (Html, a, button, div, h1, input, label, p, text)
import Html.Attributes exposing (class, disabled, href, placeholder, type_, value)
import Html.Events exposing (onClick, onInput)
import Http
import Navigation.Route as Route
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


type alias Model =
    { email : String
    , submitting : RemoteData Http.Error ()
    }


type Msg
    = SetEmail String
    | Submit
    | Completed (Result Http.Error ())


init : Model
init =
    { email = "", submitting = NotAsked }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        SetEmail val ->
            ( { model | email = val, submitting = NotAsked }, Cmd.none )

        Submit ->
            if String.isEmpty (String.trim model.email) then
                ( model, Cmd.none )

            else
                ( { model | submitting = Loading }
                , Api.forgotPassword model.email Completed
                )

        Completed result ->
            case result of
                Ok _ ->
                    ( { model | submitting = Success () }, Cmd.none )

                Err err ->
                    ( { model | submitting = Failure err }, Cmd.none )


view : Model -> Html Msg
view model =
    div [ class "page page--login" ]
        [ div [ class "login-card" ]
            [ h1 [ class "login-card__title" ] [ text "Reset your password" ]
            , case model.submitting of
                Success _ ->
                    p [ class "success", testId "forgot-success" ]
                        [ text "If that email is registered, a reset link is on its way. Check your inbox." ]

                _ ->
                    viewForm model
            ]
        ]


viewForm : Model -> Html Msg
viewForm model =
    div []
        [ p []
            [ text "Enter your email and we'll send you a link to set a new password." ]
        , div [ class "form-field" ]
            [ label [ class "form-field__label" ] [ text "Email" ]
            , input
                [ type_ "email"
                , class "form-field__input"
                , value model.email
                , onInput SetEmail
                , placeholder "you@example.com"
                , testId "forgot-email"
                ]
                []
            ]
        , case model.submitting of
            Loading ->
                button [ class "btn btn--primary btn--disabled", disabled True ]
                    [ text "Sending..." ]

            _ ->
                button [ class "btn btn--primary", onClick Submit, testId "forgot-submit" ]
                    [ text "Send reset link" ]
        , case model.submitting of
            Failure _ ->
                p [ class "error", testId "forgot-error" ]
                    [ text "Something went wrong. Please try again." ]

            _ ->
                text ""
        , p [ class "login-card__aside" ]
            [ a [ href (Route.toPath Route.Login) ] [ text "Back to sign in" ] ]
        ]
