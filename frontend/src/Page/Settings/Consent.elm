module Page.Settings.Consent exposing
    ( Model
    , Msg(..)
    , init
    , update
    , view
    )

import Api
import Html exposing (Html, button, div, h1, h2, label, p, text)
import Html.Attributes exposing (class)
import Html.Events exposing (onClick)
import Http
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { analyticsConsent : Bool
    , saving : RemoteData Http.Error ()
    }


type Msg
    = ToggleAnalytics
    | SaveConsent
    | SaveCompleted (Result Http.Error ())


init : Model
init =
    { analyticsConsent = False
    , saving = NotAsked
    }


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg )
update msg model maybeToken =
    case msg of
        ToggleAnalytics ->
            ( { model | analyticsConsent = not model.analyticsConsent }, Cmd.none )

        SaveConsent ->
            case maybeToken of
                Just token ->
                    ( { model | saving = Loading }
                    , Api.saveConsent model.analyticsConsent token SaveCompleted
                    )

                Nothing ->
                    ( model, Cmd.none )

        SaveCompleted result ->
            case result of
                Ok _ ->
                    ( { model | saving = Success () }, Cmd.none )

                Err err ->
                    ( { model | saving = Failure err }, Cmd.none )


view : Model -> Html Msg
view model =
    div [ class "page page--settings" ]
        [ h1 [ class "page__title" ] [ text "Privacy & Consent" ]
        , div [ class "settings-section" ]
            [ h2 [ class "settings-section__title" ] [ text "Analytics" ]
            , p [ class "settings-section__desc" ]
                [ text
                    "Allow us to collect anonymous usage data to improve The Stacks."
                ]
            , div [ class "toggle-row" ]
                [ label [ class "toggle-row__label" ] [ text "Analytics" ]
                , button
                    [ class
                        (if model.analyticsConsent then
                            "toggle toggle--on"

                         else
                            "toggle toggle--off"
                        )
                    , onClick ToggleAnalytics
                    ]
                    [ text
                        (if model.analyticsConsent then
                            "On"

                         else
                            "Off"
                        )
                    ]
                ]
            ]
        , div [ class "settings-actions" ]
            [ case model.saving of
                Loading ->
                    button [ class "btn btn--primary btn--disabled" ]
                        [ text "Saving..." ]

                Success _ ->
                    button [ class "btn btn--primary" ]
                        [ text "Saved!" ]

                _ ->
                    button [ class "btn btn--primary", onClick SaveConsent ]
                        [ text "Save Preferences" ]
            ]
        , case model.saving of
            Failure _ ->
                p [ class "error" ]
                    [ text "Could not save preferences. Please try again." ]

            _ ->
                text ""
        ]
