module Page.Settings.Profile exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api
import Components.SaveButton as SaveButton
import Html exposing (Html, div, h1, h2, input, label, p, text)
import Html.Attributes exposing (class, placeholder, type_, value)
import Html.Events exposing (onInput)
import Http
import Types.RemoteData exposing (RemoteData(..))
import Types.User exposing (User)


type alias Model =
    { displayName : String
    , handle : String
    , initialHandle : String
    , email : String
    , initialEmail : String
    , currentPassword : String
    , currentPasswordError : Maybe String
    , websiteUrl : String
    , countryCode : String
    , city : String
    , savingProfile : RemoteData Api.ProfileError ()
    , savingLocation : RemoteData Http.Error ()
    }


type Msg
    = SetDisplayName String
    | SetHandle String
    | SetEmail String
    | SetCurrentPassword String
    | SetWebsiteUrl String
    | SetCountryCode String
    | SetCity String
    | SaveProfile
    | SaveProfileCompleted (Result Api.ProfileError String)
    | SaveLocation
    | SaveLocationCompleted (Result Http.Error ())
    | SessionExpiryDetected


{-| `SessionExpired` bubbles to `Main.handleSessionExpiry` (#173/#178).

Until #361 this page had no `OutMsg`, so an expired session came back as
`ProfileRequestFailed (BadStatus 401)` and rendered "Could not save profile.
Please try again." — over a form still holding the reader's current password,
typed in to authorise an email change that can no longer happen.

-}
type OutMsg
    = NoOut
    | SessionExpired


init : User -> Model
init user =
    { displayName = user.displayName
    , handle = user.handle
    , initialHandle = user.handle
    , email = user.email
    , initialEmail = user.email
    , currentPassword = ""
    , currentPasswordError = Nothing
    , websiteUrl = ""
    , countryCode = Maybe.withDefault "" user.countryCode
    , city = Maybe.withDefault "" user.city
    , savingProfile = NotAsked
    , savingLocation = NotAsked
    }


{-| The email is only a _change_ when it differs from the stored value, compared
the way the server compares it (trimmed + case-insensitive — see
`Accounts.email_change?/2`). Only a real change requires the current password.
-}
emailChanged : Model -> Bool
emailChanged model =
    normaliseEmail model.email /= normaliseEmail model.initialEmail


normaliseEmail : String -> String
normaliseEmail =
    String.trim >> String.toLower


{-| The handle is only a _change_ when the field differs from the stored value.
An untouched field is never sent — for a session that carries no handle locally
the field renders empty, and sending `""` would write NULL over the real handle
(NOT NULL column → server 500). A genuine edit is sent and server-validated.
-}
handleChanged : Model -> Bool
handleChanged model =
    model.handle /= model.initialHandle


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        SetDisplayName val ->
            ( { model | displayName = val, savingProfile = NotAsked }, Cmd.none, NoOut )

        SetHandle val ->
            ( { model | handle = val, savingProfile = NotAsked }, Cmd.none, NoOut )

        SetEmail val ->
            ( { model | email = val, currentPasswordError = Nothing, savingProfile = NotAsked }, Cmd.none, NoOut )

        SetCurrentPassword val ->
            ( { model | currentPassword = val, currentPasswordError = Nothing, savingProfile = NotAsked }, Cmd.none, NoOut )

        SetWebsiteUrl val ->
            ( { model | websiteUrl = val, savingProfile = NotAsked }, Cmd.none, NoOut )

        SetCountryCode val ->
            ( { model | countryCode = val, savingLocation = NotAsked }, Cmd.none, NoOut )

        SetCity val ->
            ( { model | city = val, savingLocation = NotAsked }, Cmd.none, NoOut )

        SaveProfile ->
            if emailChanged model && String.isEmpty (String.trim model.currentPassword) then
                -- Changing the email requires the current password; block the
                -- save and surface an inline message rather than sending a
                -- request the server would reject.
                ( { model | currentPasswordError = Just "Please enter your current password to change your email." }
                , Cmd.none
                , NoOut
                )

            else
                case maybeToken of
                    Just token ->
                        ( { model | savingProfile = Loading, currentPasswordError = Nothing }
                        , Api.updateProfile
                            { displayName = model.displayName
                            , email = model.email
                            , websiteUrl = model.websiteUrl
                            , handle = model.handle
                            , currentPassword = model.currentPassword
                            , emailChanged = emailChanged model
                            , handleChanged = handleChanged model
                            }
                            (Api.authed token
                                { onExpired = SessionExpiryDetected
                                , onResult = SaveProfileCompleted
                                }
                            )
                        , NoOut
                        )

                    Nothing ->
                        ( model, Cmd.none, NoOut )

        SaveProfileCompleted result ->
            case result of
                Ok normalisedHandle ->
                    let
                        -- The 200 body echoes the server-normalised (lowercased)
                        -- handle. An omitted-handle save (unchanged field) still
                        -- echoes the real stored handle, so a session that
                        -- rendered an empty field now settles on the true value.
                        settledHandle =
                            if normalisedHandle == "" then
                                model.handle

                            else
                                normalisedHandle
                    in
                    -- Reflect the settled handle in the field and rebaseline both
                    -- the handle and email so a following untouched save omits
                    -- them. Also clear the (now consumed) password field.
                    ( { model
                        | savingProfile = Success ()
                        , initialEmail = model.email
                        , currentPassword = ""
                        , currentPasswordError = Nothing
                        , handle = settledHandle
                        , initialHandle = settledHandle
                      }
                    , Cmd.none
                    , NoOut
                    )

                Err err ->
                    -- 401 no longer arrives as `ProfileRequestFailed`: `Api.authed`
                    -- claims it before `resolveProfile` runs. A 422's field errors
                    -- still land here, which is the point of keeping them distinct.
                    ( { model | savingProfile = Failure err }, Cmd.none, NoOut )

        SaveLocation ->
            case maybeToken of
                Just token ->
                    ( { model | savingLocation = Loading }
                    , Api.updateLocation
                        { countryCode = model.countryCode, city = model.city }
                        (Api.authed token
                            { onExpired = SessionExpiryDetected
                            , onResult = SaveLocationCompleted
                            }
                        )
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        SaveLocationCompleted result ->
            case result of
                Ok _ ->
                    ( { model | savingLocation = Success () }, Cmd.none, NoOut )

                Err err ->
                    ( { model | savingLocation = Failure err }, Cmd.none, NoOut )

        SessionExpiryDetected ->
            -- Both saves route here. The model is left alone: the reader's typed
            -- values (including a current password entered for an email change)
            -- stay on screen while `Main` re-checks for a sibling tab's newer
            -- token, and are only lost if that re-check confirms the expiry.
            ( model, Cmd.none, SessionExpired )


view : Model -> Html Msg
view model =
    div [ class "page page--settings" ]
        [ h1 [ class "page__title" ] [ text "Profile" ]
        , div [ class "settings-section" ]
            [ h2 [ class "settings-section__title" ] [ text "Personal Information" ]
            , div [ class "form-field" ]
                [ label [ class "form-field__label" ] [ text "Display Name" ]
                , input
                    [ type_ "text"
                    , class "form-field__input"
                    , value model.displayName
                    , onInput SetDisplayName
                    , placeholder "Your display name"
                    ]
                    []
                ]
            , div [ class "form-field" ]
                [ label [ class "form-field__label" ] [ text "Handle" ]
                , input
                    [ type_ "text"
                    , class "form-field__input"
                    , value model.handle
                    , onInput SetHandle
                    , placeholder "your_handle"
                    ]
                    []
                , p [ class "form-field__hint" ]
                    [ text (handleHint model.handle) ]
                , viewHandleError model.savingProfile
                ]
            , div [ class "form-field" ]
                [ label [ class "form-field__label" ] [ text "Email" ]
                , input
                    [ type_ "text"
                    , class "form-field__input"
                    , value model.email
                    , onInput SetEmail
                    , placeholder "your@email.com"
                    ]
                    []
                ]
            , viewCurrentPasswordField model
            , div [ class "form-field" ]
                [ label [ class "form-field__label" ] [ text "Website URL" ]
                , input
                    [ type_ "text"
                    , class "form-field__input"
                    , value model.websiteUrl
                    , onInput SetWebsiteUrl
                    , placeholder "https://example.com"
                    ]
                    []
                ]
            , div [ class "settings-actions" ]
                [ SaveButton.primary model.savingProfile SaveProfile "Save Profile"
                ]
            , viewProfileFeedback model.savingProfile
            ]
        , div [ class "settings-section" ]
            [ h2 [ class "settings-section__title" ] [ text "Location" ]
            , div [ class "form-field" ]
                [ label [ class "form-field__label" ] [ text "Country Code" ]
                , input
                    [ type_ "text"
                    , class "form-field__input"
                    , value model.countryCode
                    , onInput SetCountryCode
                    , placeholder "US, GB, ZA, etc."
                    ]
                    []
                ]
            , div [ class "form-field" ]
                [ label [ class "form-field__label" ] [ text "City" ]
                , input
                    [ type_ "text"
                    , class "form-field__input"
                    , value model.city
                    , onInput SetCity
                    , placeholder "Your city"
                    ]
                    []
                ]
            , div [ class "settings-actions" ]
                [ SaveButton.primary model.savingLocation SaveLocation "Save Location"
                ]
            , viewFeedback model.savingLocation "Location saved." "Could not save location. Please try again."
            ]
        ]


{-| The current-password prompt only appears once the email field actually
differs from the stored value — an ordinary profile edit never sees it. When a
save is blocked for a missing password, the inline error renders beneath it.
-}
viewCurrentPasswordField : Model -> Html Msg
viewCurrentPasswordField model =
    if emailChanged model then
        div [ class "form-field" ]
            [ label [ class "form-field__label" ] [ text "Current Password" ]
            , input
                [ type_ "password"
                , class "form-field__input"
                , value model.currentPassword
                , onInput SetCurrentPassword
                , placeholder "Confirm your current password"
                ]
                []
            , p [ class "form-field__hint" ]
                [ text "Confirm your current password to change your email address." ]
            , case model.currentPasswordError of
                Just message ->
                    p [ class "form-field__error" ] [ text message ]

                Nothing ->
                    text ""
            ]

    else
        text ""


viewFeedback : RemoteData Http.Error () -> String -> String -> Html Msg
viewFeedback saving successText errorText =
    case saving of
        Success _ ->
            p [ class "success" ] [ text successText ]

        Failure _ ->
            p [ class "error" ] [ text errorText ]

        _ ->
            text ""


{-| Profile-save feedback. A validation failure renders inline under the
offending field (see `viewHandleError`), so the section-level banner stays
quiet for those — it only speaks up for success or a non-validation error.
-}
viewProfileFeedback : RemoteData Api.ProfileError () -> Html Msg
viewProfileFeedback saving =
    case saving of
        Success _ ->
            p [ class "success" ] [ text "Profile saved." ]

        Failure (Api.ProfileValidationFailed _) ->
            text ""

        Failure (Api.ProfileRequestFailed err) ->
            p [ class "error" ] [ text (profileRequestErrorText err) ]

        _ ->
            text ""


{-| A non-validation profile save failure. A wrong current password on an email
change comes back as a 422 with `{"error": "invalid_current_password"}` (no
`errors` map, so `expectProfile` classifies it as a request failure, not a field
validation) — surface the same copy the Password page uses. The endpoint can
also return 503 with a `retry-after` when Argon2 is under backpressure (an email
change hashes the current password), so that case gets its own "try again
shortly" copy; anything else is a generic save error.
-}
profileRequestErrorText : Http.Error -> String
profileRequestErrorText err =
    case err of
        Http.BadStatus 422 ->
            "Current password is incorrect."

        Http.BadStatus 503 ->
            "The server is busy right now. Please try again in a moment."

        _ ->
            "Could not save profile. Please try again."


{-| Surface a handle-specific 422 error under the handle input, mapped to the
user-facing copy from US-10.5.1.
-}
viewHandleError : RemoteData Api.ProfileError () -> Html Msg
viewHandleError saving =
    case handleErrorMessage saving of
        Just message ->
            p [ class "form-field__error" ] [ text message ]

        Nothing ->
            text ""


handleErrorMessage : RemoteData Api.ProfileError () -> Maybe String
handleErrorMessage saving =
    case saving of
        Failure (Api.ProfileValidationFailed errors) ->
            errors
                |> List.filter (\( field, _ ) -> field == "handle")
                |> List.head
                |> Maybe.andThen (\( _, messages ) -> List.head messages)
                |> Maybe.map handleErrorCopy

        _ ->
            Nothing


{-| The live public-address hint under the handle field. Shows the full address
once a handle is present, and gentle guidance while the field is empty.
-}
handleHint : String -> String
handleHint handle =
    if String.trim handle == "" then
        "Choose a handle — others will find you at thestacks.app/u/your_handle"

    else
        "Your public profile lives at thestacks.app/u/" ++ handle


handleErrorCopy : String -> String
handleErrorCopy raw =
    if String.contains "taken" raw then
        "That handle is already taken."

    else if String.contains "reserved" raw then
        "That handle is reserved."

    else
        "Handle must be 3–30 characters: lowercase letters, numbers, underscores."
