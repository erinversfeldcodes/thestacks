module Page.Settings.Notifications exposing
    ( Model
    , Msg(..)
    , init
    , update
    , view
    )

import Api exposing (NotificationPreferences)
import Html exposing (Html, button, div, h1, h2, label, p, text)
import Html.Attributes exposing (class)
import Html.Events exposing (onClick)
import Http
import Types.RemoteData exposing (RemoteData(..))


{-| The preferences hydrate from the server (`GET /api/settings/notifications`)
rather than rendering hardcoded defaults: showing toggles at silently-wrong
values would let a user "confirm" a state that is not what is stored. Toggles
only render once the real values load; a load failure shows an error instead.
-}
type alias Model =
    { prefs : RemoteData Http.Error NotificationPreferences
    , saving : RemoteData Http.Error ()
    }


type Msg
    = Loaded (Result Http.Error NotificationPreferences)
    | TogglePriceDrops
    | ToggleNewReviews
    | ToggleAuthorUpdates
    | ToggleEventAlerts
    | SaveCompleted (Result Http.Error ())


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    ( { prefs = Loading, saving = NotAsked }
    , case maybeToken of
        Just token ->
            Api.getNotifications token Loaded

        Nothing ->
            Cmd.none
    )


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg )
update msg model maybeToken =
    case msg of
        Loaded (Ok prefs) ->
            ( { model | prefs = Success prefs }, Cmd.none )

        Loaded (Err err) ->
            ( { model | prefs = Failure err }, Cmd.none )

        TogglePriceDrops ->
            flipAndSave model maybeToken (\prefs -> { prefs | priceDrops = not prefs.priceDrops })

        ToggleNewReviews ->
            flipAndSave model maybeToken (\prefs -> { prefs | newReviews = not prefs.newReviews })

        ToggleAuthorUpdates ->
            flipAndSave model maybeToken (\prefs -> { prefs | authorUpdates = not prefs.authorUpdates })

        ToggleEventAlerts ->
            flipAndSave model maybeToken (\prefs -> { prefs | eventAlerts = not prefs.eventAlerts })

        SaveCompleted result ->
            case result of
                Ok _ ->
                    ( { model | saving = Success () }, Cmd.none )

                Err err ->
                    ( { model | saving = Failure err }, Cmd.none )


{-| Flip one preference on the loaded values and immediately auto-save. A toggle
is a no-op until the preferences have loaded — there is nothing to flip yet.
-}
flipAndSave : Model -> Maybe String -> (NotificationPreferences -> NotificationPreferences) -> ( Model, Cmd Msg )
flipAndSave model maybeToken flip =
    case model.prefs of
        Success prefs ->
            let
                newPrefs =
                    flip prefs
            in
            ( { model | prefs = Success newPrefs, saving = NotAsked }
            , savePreferences newPrefs maybeToken
            )

        _ ->
            ( model, Cmd.none )


savePreferences : NotificationPreferences -> Maybe String -> Cmd Msg
savePreferences prefs maybeToken =
    case maybeToken of
        Just token ->
            Api.updateNotifications prefs token SaveCompleted

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
            , viewPreferences model.prefs
            ]
        , viewSaveFeedback model.saving
        ]


viewPreferences : RemoteData Http.Error NotificationPreferences -> Html Msg
viewPreferences prefs =
    case prefs of
        Success loaded ->
            div [ class "notification-toggles" ]
                [ viewToggle "Price Drops" loaded.priceDrops TogglePriceDrops
                , viewToggle "New Reviews" loaded.newReviews ToggleNewReviews
                , viewToggle "Author Updates" loaded.authorUpdates ToggleAuthorUpdates
                , viewToggle "Event Alerts" loaded.eventAlerts ToggleEventAlerts
                ]

        Failure _ ->
            p [ class "error" ]
                [ text "Could not load your notification preferences. Please refresh to try again." ]

        _ ->
            p [ class "settings-section__desc" ]
                [ text "Loading your preferences…" ]


viewSaveFeedback : RemoteData Http.Error () -> Html Msg
viewSaveFeedback saving =
    case saving of
        Failure _ ->
            p [ class "error" ]
                [ text "Could not save notification preferences. Please try again." ]

        Success _ ->
            p [ class "success" ]
                [ text "Preferences saved." ]

        _ ->
            text ""


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
