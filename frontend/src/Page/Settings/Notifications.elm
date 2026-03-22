module Page.Settings.Notifications exposing
    ( Model
    , Msg
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
    { priceDrops : Bool
    , newReviews : Bool
    , authorUpdates : Bool
    , eventAlerts : Bool
    , saving : RemoteData Http.Error ()
    }


type Msg
    = TogglePriceDrops
    | ToggleNewReviews
    | ToggleAuthorUpdates
    | ToggleEventAlerts
    | SaveCompleted (Result Http.Error ())


init : Model
init =
    { priceDrops = False
    , newReviews = False
    , authorUpdates = False
    , eventAlerts = False
    , saving = NotAsked
    }


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg )
update msg model maybeToken =
    case msg of
        TogglePriceDrops ->
            let
                newModel =
                    { model | priceDrops = not model.priceDrops, saving = NotAsked }
            in
            ( newModel, savePreferences newModel maybeToken )

        ToggleNewReviews ->
            let
                newModel =
                    { model | newReviews = not model.newReviews, saving = NotAsked }
            in
            ( newModel, savePreferences newModel maybeToken )

        ToggleAuthorUpdates ->
            let
                newModel =
                    { model | authorUpdates = not model.authorUpdates, saving = NotAsked }
            in
            ( newModel, savePreferences newModel maybeToken )

        ToggleEventAlerts ->
            let
                newModel =
                    { model | eventAlerts = not model.eventAlerts, saving = NotAsked }
            in
            ( newModel, savePreferences newModel maybeToken )

        SaveCompleted result ->
            case result of
                Ok _ ->
                    ( { model | saving = Success () }, Cmd.none )

                Err err ->
                    ( { model | saving = Failure err }, Cmd.none )


savePreferences : Model -> Maybe String -> Cmd Msg
savePreferences model maybeToken =
    case maybeToken of
        Just token ->
            Api.updateNotifications
                { priceDrops = model.priceDrops
                , newReviews = model.newReviews
                , authorUpdates = model.authorUpdates
                , eventAlerts = model.eventAlerts
                }
                token
                SaveCompleted

        Nothing ->
            Cmd.none


view : Model -> Html Msg
view model =
    div [ class "page page--settings" ]
        [ h1 [ class "page__title" ] [ text "Notifications" ]
        , div [ class "settings-section" ]
            [ h2 [ class "settings-section__title" ] [ text "Notification Preferences" ]
            , p [ class "settings-section__desc" ]
                [ text "Choose which notifications you would like to receive." ]
            , viewToggle "Price Drops" model.priceDrops TogglePriceDrops
            , viewToggle "New Reviews" model.newReviews ToggleNewReviews
            , viewToggle "Author Updates" model.authorUpdates ToggleAuthorUpdates
            , viewToggle "Event Alerts" model.eventAlerts ToggleEventAlerts
            ]
        , case model.saving of
            Failure _ ->
                p [ class "error" ]
                    [ text "Could not save notification preferences. Please try again." ]

            Success _ ->
                p [ class "success" ]
                    [ text "Preferences saved." ]

            _ ->
                text ""
        ]


viewToggle : String -> Bool -> Msg -> Html Msg
viewToggle labelText isOn toggleMsg =
    div [ class "toggle-row" ]
        [ label [ class "toggle-row__label" ] [ text labelText ]
        , button
            [ class
                (if isOn then
                    "toggle toggle--on"

                 else
                    "toggle toggle--off"
                )
            , onClick toggleMsg
            ]
            [ text
                (if isOn then
                    "On"

                 else
                    "Off"
                )
            ]
        ]
