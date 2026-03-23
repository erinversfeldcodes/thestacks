module Page.Settings.Profile exposing
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
import Types.User exposing (User)


type alias Model =
    { displayName : String
    , email : String
    , websiteUrl : String
    , countryCode : String
    , city : String
    , savingProfile : RemoteData Http.Error ()
    , savingLocation : RemoteData Http.Error ()
    }


type Msg
    = SetDisplayName String
    | SetEmail String
    | SetWebsiteUrl String
    | SetCountryCode String
    | SetCity String
    | SaveProfile
    | SaveProfileCompleted (Result Http.Error ())
    | SaveLocation
    | SaveLocationCompleted (Result Http.Error ())


init : User -> Model
init user =
    { displayName = user.displayName
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
                        }
                        token
                        SaveProfileCompleted
                    )

                Nothing ->
                    ( model, Cmd.none )

        SaveProfileCompleted result ->
            case result of
                Ok _ ->
                    ( { model | savingProfile = Success () }, Cmd.none )

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
            , viewFeedback model.savingProfile "Profile saved." "Could not save profile. Please try again."
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


viewSaveButton : RemoteData Http.Error () -> Msg -> String -> Html Msg
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
