module Page.Settings.Profile exposing
    ( Model
    , Msg(..)
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
import Types.User exposing (User)


type alias Model =
    { displayName : String
    , handle : String
    , email : String
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
    | SetWebsiteUrl String
    | SetCountryCode String
    | SetCity String
    | SaveProfile
    | SaveProfileCompleted (Result Api.ProfileError String)
    | SaveLocation
    | SaveLocationCompleted (Result Http.Error ())


init : User -> Model
init user =
    { displayName = user.displayName
    , handle = user.handle
    , email = user.email
    , websiteUrl = ""
    , countryCode = Maybe.withDefault "" user.countryCode
    , city = Maybe.withDefault "" user.city
    , savingProfile = NotAsked
    , savingLocation = NotAsked
    }


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg )
update msg model maybeToken =
    case msg of
        SetDisplayName val ->
            ( { model | displayName = val, savingProfile = NotAsked }, Cmd.none )

        SetHandle val ->
            ( { model | handle = val, savingProfile = NotAsked }, Cmd.none )

        SetEmail val ->
            ( { model | email = val, savingProfile = NotAsked }, Cmd.none )

        SetWebsiteUrl val ->
            ( { model | websiteUrl = val, savingProfile = NotAsked }, Cmd.none )

        SetCountryCode val ->
            ( { model | countryCode = val, savingLocation = NotAsked }, Cmd.none )

        SetCity val ->
            ( { model | city = val, savingLocation = NotAsked }, Cmd.none )

        SaveProfile ->
            case maybeToken of
                Just token ->
                    ( { model | savingProfile = Loading }
                    , Api.updateProfile
                        { displayName = model.displayName
                        , email = model.email
                        , websiteUrl = model.websiteUrl
                        , handle = model.handle
                        }
                        token
                        SaveProfileCompleted
                    )

                Nothing ->
                    ( model, Cmd.none )

        SaveProfileCompleted result ->
            case result of
                Ok normalisedHandle ->
                    -- The 200 body echoes the server-normalised (lowercased) handle;
                    -- reflect it so the field shows exactly what was stored.
                    ( { model
                        | savingProfile = Success ()
                        , handle =
                            if normalisedHandle == "" then
                                model.handle

                            else
                                normalisedHandle
                      }
                    , Cmd.none
                    )

                Err err ->
                    ( { model | savingProfile = Failure err }, Cmd.none )

        SaveLocation ->
            case maybeToken of
                Just token ->
                    ( { model | savingLocation = Loading }
                    , Api.updateLocation
                        { countryCode = model.countryCode, city = model.city }
                        token
                        SaveLocationCompleted
                    )

                Nothing ->
                    ( model, Cmd.none )

        SaveLocationCompleted result ->
            case result of
                Ok _ ->
                    ( { model | savingLocation = Success () }, Cmd.none )

                Err err ->
                    ( { model | savingLocation = Failure err }, Cmd.none )


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
                    [ text "Your public address: the stacks/u/" ]
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
                [ viewSaveButton model.savingProfile SaveProfile "Save Profile"
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
                [ viewSaveButton model.savingLocation SaveLocation "Save Location"
                ]
            , viewFeedback model.savingLocation "Location saved." "Could not save location. Please try again."
            ]
        ]


viewSaveButton : RemoteData e () -> Msg -> String -> Html Msg
viewSaveButton saving onClickMsg label =
    case saving of
        Loading ->
            button [ class "btn btn--primary btn--disabled", disabled True ]
                [ text "Saving..." ]

        Success _ ->
            button [ class "btn btn--primary" ]
                [ text "Saved!" ]

        _ ->
            button [ class "btn btn--primary", onClick onClickMsg ]
                [ text label ]


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


{-| A non-validation profile save failure. The endpoint can return 503 with a
`retry-after` when Argon2 is under backpressure (an email change hashes the
current password), so that case gets its own "try again shortly" copy; anything
else is a generic save error.
-}
profileRequestErrorText : Http.Error -> String
profileRequestErrorText err =
    case err of
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


handleErrorCopy : String -> String
handleErrorCopy raw =
    if String.contains "taken" raw then
        "That handle is already taken."

    else if String.contains "reserved" raw then
        "That handle is reserved."

    else
        "Handle must be 3–30 characters: lowercase letters, numbers, underscores."
