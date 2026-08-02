module Page.Settings.Notifications exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
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
import Util.FailureCopy as FailureCopy


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
    | SessionExpiryDetected


{-| `SessionExpired` bubbles to `Main.handleSessionExpiry` (#173/#178).

Until #361 this page had no `OutMsg`, so an expired session showed either
"Could not load your notification preferences. Please refresh to try again." or
"Could not save notification preferences. Please try again." Refreshing an
expired session reloads the same 401; the toggle, meanwhile, had already been
flipped optimistically, so the reader was looking at a value the server never
stored.

-}
type OutMsg
    = NoOut
    | SessionExpired


{-| `init` keeps its 2-tuple: the load's 401 arrives as `SessionExpiryDetected`
in `update`, which is the only place an `OutMsg` can be raised anyway.
-}
init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    case maybeToken of
        Just token ->
            ( { prefs = Loading, saving = NotAsked }
            , Api.getNotifications
                (Api.authed token
                    { onExpired = SessionExpiryDetected
                    , onResult = Loaded
                    }
                )
            )

        Nothing ->
            -- No token means no request is in flight: Loading here would
            -- render "Loading your preferences…" forever (#324 0h).
            ( { prefs = NotAsked, saving = NotAsked }, Cmd.none )


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        Loaded (Ok prefs) ->
            ( { model | prefs = Success prefs }, Cmd.none, NoOut )

        Loaded (Err err) ->
            ( { model | prefs = Failure err }, Cmd.none, NoOut )

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
                    ( { model | saving = Success () }, Cmd.none, NoOut )

                Err err ->
                    -- 401 is gone from this branch: `Api.authed` claims it first.
                    ( { model | saving = Failure err }, Cmd.none, NoOut )

        SessionExpiryDetected ->
            ( model, Cmd.none, SessionExpired )


{-| Flip one preference on the loaded values and immediately auto-save. A toggle
is a no-op until the preferences have loaded — there is nothing to flip yet.
-}
flipAndSave : Model -> Maybe String -> (NotificationPreferences -> NotificationPreferences) -> ( Model, Cmd Msg, OutMsg )
flipAndSave model maybeToken flip =
    case model.prefs of
        Success prefs ->
            let
                newPrefs =
                    flip prefs
            in
            ( { model | prefs = Success newPrefs, saving = NotAsked }
            , savePreferences newPrefs maybeToken
            , NoOut
            )

        _ ->
            ( model, Cmd.none, NoOut )


savePreferences : NotificationPreferences -> Maybe String -> Cmd Msg
savePreferences prefs maybeToken =
    case maybeToken of
        Just token ->
            Api.updateNotifications prefs
                (Api.authed token
                    { onExpired = SessionExpiryDetected
                    , onResult = SaveCompleted
                    }
                )

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

        NotAsked ->
            text ""

        Loading ->
            p [ class "settings-section__desc" ]
                [ text "Loading your preferences…" ]


{-| ⛔ The save feedback says WHICH failure (Issue #374).

"Could not save notification preferences. Please try again." was shown for a
422 the reader cannot fix by repeating it, a dropped connection they can fix but
not here, and a timeout after which the change may well have been saved — the
one case where trying again is actively the wrong advice, because it invites a
second write to settle a question a reload answers.

The 401 leg is not here and must not be added: `Api.Authed` routes an expired
session to `SessionExpired` before this state can be reached (#361).

-}
viewSaveFeedback : RemoteData Http.Error () -> Html Msg
viewSaveFeedback saving =
    case saving of
        Failure err ->
            p [ class "error" ]
                [ text (FailureCopy.saveFailure "your notification preferences" err) ]

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
