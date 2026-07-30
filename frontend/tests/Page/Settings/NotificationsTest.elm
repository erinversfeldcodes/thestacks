module Page.Settings.NotificationsTest exposing (suite)

{-| #126 CG-2 (US-17.3.1) — the Settings → Notifications toggles hydrate from the
server instead of rendering hardcoded defaults.

Drives `Page.Settings.Notifications.update`/`view` through the load lifecycle:
`init` starts in Loading, a `Loaded Ok` renders the toggles at their saved (non
default) values, a `Loaded Err` renders an error with NO toggles at wrong
defaults, and toggling a loaded preference flips it and reports the save.

-}

import Api
import Expect
import Http
import Page.Settings.Notifications as Notifications exposing (Msg(..))
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.RemoteData exposing (RemoteData(..))


allOn : Api.NotificationPreferences
allOn =
    { priceDrops = True
    , newReviews = True
    , authorUpdates = True
    , eventAlerts = True
    }


allOff : Api.NotificationPreferences
allOff =
    { priceDrops = False
    , newReviews = False
    , authorUpdates = False
    , eventAlerts = False
    }


{-| A model that has finished loading the given preferences from the server.
-}
loadedWith : Api.NotificationPreferences -> Notifications.Model
loadedWith prefs =
    Notifications.init (Just "test-token")
        |> Tuple.first
        |> (\model -> Notifications.update (Loaded (Ok prefs)) model (Just "test-token"))
        |> Tuple.first


toggleButtons : Notifications.Model -> Query.Single Msg
toggleButtons model =
    Notifications.view model
        |> Query.fromHtml


suite : Test
suite =
    describe "Page.Settings.Notifications — hydration (#126 CG-2)"
        [ test "init starts in the Loading state (no toggles at silently-wrong defaults)" <|
            \_ ->
                Notifications.init (Just "test-token")
                    |> Tuple.first
                    |> .prefs
                    |> Expect.equal Loading
        , test "tokenless init yields NotAsked, not a Loading state nothing will resolve (#324 0h)" <|
            \_ ->
                -- With no auth token there is no request to await; Loading with
                -- Cmd.none would render "Loading your preferences…" forever.
                Notifications.init Nothing
                    |> Tuple.first
                    |> .prefs
                    |> Expect.equal NotAsked
        , test "tokenless init produces no effect (#324 0h)" <|
            \_ ->
                Notifications.init Nothing
                    |> Tuple.second
                    |> Expect.equal Cmd.none
        , test "tokenless init does not render the loading copy (#324 0h)" <|
            \_ ->
                Notifications.init Nothing
                    |> Tuple.first
                    |> Notifications.view
                    |> Query.fromHtml
                    |> Query.hasNot [ Selector.text "Loading your preferences…" ]
        , test "a successful load renders toggles at the saved values, not defaults" <|
            \_ ->
                -- Defaults would show every toggle Off; loading all-on proves the
                -- rendered state comes from the server, not the hardcoded default.
                loadedWith allOn
                    |> toggleButtons
                    |> Query.findAll [ Selector.class "toggle--on" ]
                    |> Query.count (Expect.equal 4)
        , test "a successful load renders mixed saved values faithfully" <|
            \_ ->
                loadedWith { allOff | priceDrops = True }
                    |> toggleButtons
                    |> Query.findAll [ Selector.class "toggle--on" ]
                    |> Query.count (Expect.equal 1)
        , test "a load failure renders an error and no toggles" <|
            \_ ->
                let
                    failed =
                        Notifications.init (Just "test-token")
                            |> Tuple.first
                            |> (\model -> Notifications.update (Loaded (Err (Http.BadStatus 500))) model (Just "test-token"))
                            |> Tuple.first
                in
                Expect.all
                    [ \_ ->
                        Notifications.view failed
                            |> Query.fromHtml
                            |> Query.has [ Selector.text "Could not load your notification preferences. Please refresh to try again." ]
                    , \_ ->
                        Notifications.view failed
                            |> Query.fromHtml
                            |> Query.findAll [ Selector.class "toggle" ]
                            |> Query.count (Expect.equal 0)
                    ]
                    ()
        , test "toggling a loaded preference flips only that value" <|
            \_ ->
                Notifications.update TogglePriceDrops (loadedWith allOff) (Just "test-token")
                    |> Tuple.first
                    |> .prefs
                    |> Expect.equal (Success { allOff | priceDrops = True })
        , test "ToggleNewReviews flips only new reviews" <|
            \_ ->
                Notifications.update ToggleNewReviews (loadedWith allOff) (Just "test-token")
                    |> Tuple.first
                    |> .prefs
                    |> Expect.equal (Success { allOff | newReviews = True })
        , test "ToggleAuthorUpdates flips only author updates" <|
            \_ ->
                Notifications.update ToggleAuthorUpdates (loadedWith allOff) (Just "test-token")
                    |> Tuple.first
                    |> .prefs
                    |> Expect.equal (Success { allOff | authorUpdates = True })
        , test "ToggleEventAlerts flips only event alerts" <|
            \_ ->
                Notifications.update ToggleEventAlerts (loadedWith allOff) (Just "test-token")
                    |> Tuple.first
                    |> .prefs
                    |> Expect.equal (Success { allOff | eventAlerts = True })
        , test "toggling a loaded preference clears any prior save result" <|
            \_ ->
                -- flipAndSave resets `saving` to NotAsked as it dispatches the
                -- auto-save, so a stale "Preferences saved." banner cannot linger
                -- over a freshly-flipped (not-yet-confirmed) value.
                loadedWith allOff
                    |> (\model -> Notifications.update (SaveCompleted (Ok ())) model (Just "test-token"))
                    |> Tuple.first
                    |> (\model -> Notifications.update ToggleNewReviews model (Just "test-token"))
                    |> Tuple.first
                    |> .saving
                    |> Expect.equal NotAsked
        , test "a toggle before the preferences load is a no-op" <|
            \_ ->
                let
                    loadingModel =
                        Notifications.init (Just "test-token") |> Tuple.first
                in
                Notifications.update TogglePriceDrops loadingModel (Just "test-token")
                    |> Tuple.first
                    |> .prefs
                    |> Expect.equal Loading
        , test "a completed save shows the saved confirmation" <|
            \_ ->
                Notifications.update (SaveCompleted (Ok ())) (loadedWith allOff) (Just "test-token")
                    |> Tuple.first
                    |> Notifications.view
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "Preferences saved." ]
        , test "a failed save shows the save-error copy" <|
            \_ ->
                Notifications.update (SaveCompleted (Err Http.NetworkError)) (loadedWith allOff) (Just "test-token")
                    |> Tuple.first
                    |> Notifications.view
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "Could not save notification preferences. Please try again." ]
        ]
