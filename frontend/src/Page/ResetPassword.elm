module Page.ResetPassword exposing
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
    { token : String
    , password : String
    , confirmPassword : String
    , submitting : RemoteData Http.Error ()
    }


type Msg
    = SetPassword String
    | SetConfirmPassword String
    | Submit
    | Completed (Result Http.Error ())


init : String -> Model
init token =
    { token = token
    , password = ""
    , confirmPassword = ""
    , submitting = NotAsked
    }


{-| A blocking validation error, or Nothing when the form may be submitted.
-}
validate : Model -> Maybe String
validate model =
    if String.length model.password < 8 then
        Just "Password must be at least 8 characters."

    else if model.password /= model.confirmPassword then
        Just "Passwords do not match."

    else
        Nothing


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        SetPassword val ->
            ( { model | password = val, submitting = NotAsked }, Cmd.none )

        SetConfirmPassword val ->
            ( { model | confirmPassword = val, submitting = NotAsked }, Cmd.none )

        Submit ->
            case validate model of
                Just _ ->
                    ( model, Cmd.none )

                Nothing ->
                    ( { model | submitting = Loading }
                    , Api.resetPassword
                        { token = model.token, password = model.password }
                        Completed
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
            [ h1 [ class "login-card__title" ] [ text "Choose a new password" ]
            , case model.submitting of
                Success _ ->
                    div [ testId "reset-success" ]
                        [ p [ class "success" ] [ text "Your password has been reset." ]
                        , a
                            [ class "btn btn--primary"
                            , href (Route.toPath Route.Login)
                            , testId "reset-login-link"
                            ]
                            [ text "Sign in" ]
                        ]

                _ ->
                    viewForm model
            ]
        ]


viewForm : Model -> Html Msg
viewForm model =
    let
        validationError =
            if
                model.submitting
                    == NotAsked
                    && (not (String.isEmpty model.password) || not (String.isEmpty model.confirmPassword))
            then
                validate model

            else
                Nothing
    in
    div []
        [ div [ class "form-field" ]
            [ label [ class "form-field__label" ] [ text "New password" ]
            , input
                [ type_ "password"
                , class "form-field__input"
                , value model.password
                , onInput SetPassword
                , placeholder "At least 8 characters"
                , testId "reset-password"
                ]
                []
            ]
        , div [ class "form-field" ]
            [ label [ class "form-field__label" ] [ text "Confirm new password" ]
            , input
                [ type_ "password"
                , class "form-field__input"
                , value model.confirmPassword
                , onInput SetConfirmPassword
                , placeholder "Repeat new password"
                , testId "reset-confirm"
                ]
                []
            ]
        , case validationError of
            Just errMsg ->
                p [ class "error" ] [ text errMsg ]

            Nothing ->
                text ""
        , case model.submitting of
            Loading ->
                button [ class "btn btn--primary btn--disabled", disabled True ]
                    [ text "Resetting..." ]

            _ ->
                button [ class "btn btn--primary", onClick Submit, testId "reset-submit" ]
                    [ text "Reset password" ]
        , case model.submitting of
            Failure (Http.BadStatus 400) ->
                p [ class "error", testId "reset-error" ]
                    [ text "This reset link is invalid or has expired. Request a new one." ]

            Failure (Http.BadStatus 422) ->
                p [ class "error", testId "reset-error" ]
                    [ text "Password must be at least 8 characters." ]

            Failure _ ->
                p [ class "error", testId "reset-error" ]
                    [ text "Something went wrong. Please try again." ]

            _ ->
                text ""
        ]
