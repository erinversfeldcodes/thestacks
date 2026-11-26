module Page.Settings.Password exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api
import Components.SaveButton as SaveButton
import Effect exposing (Effect)
import Html exposing (Html, div, h1, h2, input, label, p, text)
import Html.Attributes exposing (class, placeholder, type_, value)
import Html.Events exposing (onInput)
import Http
import Types.PasswordRule as PasswordRule
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
    | SessionExpiryDetected


{-| `SessionExpired` bubbles to `Main.handleSessionExpiry`: the
re-check net that adopts a sibling tab's newer token before it logs anyone out.

Until this page had no `OutMsg` at all, so a mid-form 401 landed in
`SaveCompleted`'s `Err` branch and rendered "Could not change password. Please
try again." — asking the reader to retype a password into a form whose session
no longer exists.

-}
type OutMsg
    = NoOut
    | SessionExpired


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
    if not (PasswordRule.isLongEnough model.newPassword) then
        Just (PasswordRule.tooShortFor "New password")

    else if model.newPassword /= model.confirmPassword then
        Just "New password and confirmation do not match."

    else if String.isEmpty model.currentPassword then
        Just "Please enter your current password."

    else
        Nothing


update : Msg -> Model -> Maybe Api.Credentials -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    let
        ( newModel, effect, out ) =
            updateWithEffect msg model maybeToken
    in
    ( newModel, Effect.perform effect, out )


updateWithEffect : Msg -> Model -> Maybe Api.Credentials -> ( Model, Effect Msg, OutMsg )
updateWithEffect msg model maybeToken =
    case msg of
        SetCurrentPassword val ->
            ( { model | currentPassword = val, saving = NotAsked }, Effect.None, NoOut )

        SetNewPassword val ->
            ( { model | newPassword = val, saving = NotAsked }, Effect.None, NoOut )

        SetConfirmPassword val ->
            ( { model | confirmPassword = val, saving = NotAsked }, Effect.None, NoOut )

        SavePassword ->
            case validate model of
                Just _ ->
                    ( model, Effect.None, NoOut )

                Nothing ->
                    case maybeToken of
                        Just token ->
                            ( { model | saving = Loading }
                            , Effect.authed
                                (Api.updatePasswordRequest
                                    { currentPassword = model.currentPassword
                                    , newPassword = model.newPassword
                                    }
                                )
                                token
                                { onExpired = SessionExpiryDetected
                                , onResponse = Api.resolveWhatever >> SaveCompleted
                                }
                            , NoOut
                            )

                        Nothing ->
                            ( model, Effect.None, NoOut )

        SaveCompleted result ->
            case result of
                Ok _ ->
                    ( { init | saving = Success () }, Effect.None, NoOut )

                Err err ->
                    ( { model | saving = Failure err }, Effect.None, NoOut )

        SessionExpiryDetected ->
            ( model, Effect.None, SessionExpired )


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
                    , placeholder PasswordRule.requirementHint
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
                [ SaveButton.primary model.saving SavePassword "Change Password" ]
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
