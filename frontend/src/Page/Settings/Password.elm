module Page.Settings.Password exposing
    ( Model
    , Msg
    , init
    , update
    , view
    )

import Api
import Html exposing (Html, button, div, h1, h2, input, label, p, text)
import Html.Attributes exposing (class, disabled, placeholder, type_, value)
import Html.Events exposing (onClick, onInput)
import Http
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { currentPassword : String
    , newPassword : String
    , confirmPassword : String
    , saving : RemoteData Http.Error ()
    }


type Msg
    = SetCurrentPassword String
    | SetNewPassword String
    | SetConfirmPassword String
    | SavePassword
    | SaveCompleted (Result Http.Error ())


init : Model
init =
    { currentPassword = ""
    , newPassword = ""
    , confirmPassword = ""
    , saving = NotAsked
    }


type alias ValidationError =
    String


validate : Model -> Maybe ValidationError
validate model =
    if String.length model.newPassword < 8 then
        Just "New password must be at least 8 characters."

    else if model.newPassword /= model.confirmPassword then
        Just "New password and confirmation do not match."

    else if String.isEmpty model.currentPassword then
        Just "Please enter your current password."

    else
        Nothing


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg )
update msg model maybeToken =
    case msg of
        SetCurrentPassword val ->
            ( { model | currentPassword = val, saving = NotAsked }, Cmd.none )

        SetNewPassword val ->
            ( { model | newPassword = val, saving = NotAsked }, Cmd.none )

        SetConfirmPassword val ->
            ( { model | confirmPassword = val, saving = NotAsked }, Cmd.none )

        SavePassword ->
            case validate model of
                Just _ ->
                    ( model, Cmd.none )

                Nothing ->
                    case maybeToken of
                        Just token ->
                            ( { model | saving = Loading }
                            , Api.updatePassword
                                { currentPassword = model.currentPassword
                                , newPassword = model.newPassword
                                }
                                token
                                SaveCompleted
                            )

                        Nothing ->
                            ( model, Cmd.none )

        SaveCompleted result ->
            case result of
                Ok _ ->
                    ( { init | saving = Success () }, Cmd.none )

                Err err ->
                    ( { model | saving = Failure err }, Cmd.none )


view : Model -> Html Msg
view model =
    let
        validationError =
            if model.saving == NotAsked && (not (String.isEmpty model.newPassword) || not (String.isEmpty model.confirmPassword)) then
                validate model

            else
                Nothing
    in
    div [ class "page page--settings" ]
        [ h1 [ class "page__title" ] [ text "Password" ]
        , div [ class "settings-section" ]
            [ h2 [ class "settings-section__title" ] [ text "Change Password" ]
            , div [ class "form-field" ]
                [ label [ class "form-field__label" ] [ text "Current Password" ]
                , input
                    [ type_ "password"
                    , class "form-field__input"
                    , value model.currentPassword
                    , onInput SetCurrentPassword
                    , placeholder "Enter current password"
                    ]
                    []
                ]
            , div [ class "form-field" ]
                [ label [ class "form-field__label" ] [ text "New Password" ]
                , input
                    [ type_ "password"
                    , class "form-field__input"
                    , value model.newPassword
                    , onInput SetNewPassword
                    , placeholder "At least 8 characters"
                    ]
                    []
                ]
            , div [ class "form-field" ]
                [ label [ class "form-field__label" ] [ text "Confirm New Password" ]
                , input
                    [ type_ "password"
                    , class "form-field__input"
                    , value model.confirmPassword
                    , onInput SetConfirmPassword
                    , placeholder "Repeat new password"
                    ]
                    []
                ]
            , case validationError of
                Just errMsg ->
                    p [ class "error" ] [ text errMsg ]

                Nothing ->
                    text ""
            , div [ class "settings-actions" ]
                [ case model.saving of
                    Loading ->
                        button [ class "btn btn--primary btn--disabled", disabled True ]
                            [ text "Saving..." ]

                    _ ->
                        button [ class "btn btn--primary", onClick SavePassword ]
                            [ text "Change Password" ]
                ]
            , case model.saving of
                Success _ ->
                    p [ class "success" ] [ text "Password changed successfully." ]

                Failure (Http.BadStatus 422) ->
                    p [ class "error" ] [ text "Current password is incorrect." ]

                Failure _ ->
                    p [ class "error" ] [ text "Could not change password. Please try again." ]

                _ ->
                    text ""
            ]
        ]
