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


{-| The model out of the page's `( Model, Cmd Msg, OutMsg )` triple. The page
gained an `OutMsg` in #361 so a mid-form 401 can reach the global session-expiry
interceptor; the `OutMsg` itself is asserted in `Page.SessionExpiryPagesTest`.
-}
modelOf : ( Notifications.Model, Cmd Msg, Notifications.OutMsg ) -> Notifications.Model
modelOf ( model, _, _ ) =
    model


{-| A model that has finished loading the given preferences from the server.
-}
loadedWith : Api.NotificationPreferences -> Notifications.Model
loadedWith prefs =
    Notifications.init (Just "test-token")
        |> Tuple.first
        |> (\model -> Notifications.update (Loaded (Ok prefs)) model (Just "test-token"))
        |> modelOf


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
                            |> modelOf
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
                    |> modelOf
                    |> .prefs
                    |> Expect.equal (Success { allOff | priceDrops = True })
        , test "ToggleNewReviews flips only new reviews" <|
            \_ ->
                Notifications.update ToggleNewReviews (loadedWith allOff) (Just "test-token")
                    |> modelOf
                    |> .prefs
                    |> Expect.equal (Success { allOff | newReviews = True })
        , test "ToggleAuthorUpdates flips only author updates" <|
            \_ ->
                Notifications.update ToggleAuthorUpdates (loadedWith allOff) (Just "test-token")
                    |> modelOf
                    |> .prefs
                    |> Expect.equal (Success { allOff | authorUpdates = True })
        , test "ToggleEventAlerts flips only event alerts" <|
            \_ ->
                Notifications.update ToggleEventAlerts (loadedWith allOff) (Just "test-token")
                    |> modelOf
                    |> .prefs
                    |> Expect.equal (Success { allOff | eventAlerts = True })
        , test "toggling a loaded preference clears any prior save result" <|
            \_ ->
                loadedWith allOff
                    |> (\model -> Notifications.update (SaveCompleted (Ok ())) model (Just "test-token"))
                    |> modelOf
                    |> (\model -> Notifications.update ToggleNewReviews model (Just "test-token"))
                    |> modelOf
                    |> .saving
                    |> Expect.equal NotAsked
        , test "a toggle before the preferences load is a no-op" <|
            \_ ->
                let
                    loadingModel =
                        Notifications.init (Just "test-token") |> Tuple.first
                in
                Notifications.update TogglePriceDrops loadingModel (Just "test-token")
                    |> modelOf
                    |> .prefs
                    |> Expect.equal Loading
        , test "a completed save shows the saved confirmation" <|
            \_ ->
                Notifications.update (SaveCompleted (Ok ())) (loadedWith allOff) (Just "test-token")
                    |> modelOf
                    |> Notifications.view
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "Preferences saved." ]
        , test "a dropped connection says the connection dropped" <|
            \_ ->
                Notifications.update (SaveCompleted (Err Http.NetworkError)) (loadedWith allOff) (Just "test-token")
                    |> modelOf
                    |> Notifications.view
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "The library is unreachable, so your notification preferences were not saved." ]
        , -- ⛔ #374. All three of these were "Could not save notification
          test "a 422 sends the reader to a reload, not to a repeat" <|
            \_ ->
                Notifications.update (SaveCompleted (Err (Http.BadStatus 422))) (loadedWith allOff) (Just "test-token")
                    |> modelOf
                    |> Notifications.view
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "The library would not accept that change to your notification preferences. Reload the page and try again." ]
        , test "a timeout does not claim the change was lost" <|
            \_ ->
                Notifications.update (SaveCompleted (Err Http.Timeout)) (loadedWith allOff) (Just "test-token")
                    |> modelOf
                    |> Notifications.view
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "we cannot say whether your notification preferences were saved" ]
        , test "an unrecognised status admits it is unrecognised" <|
            \_ ->
                Notifications.update (SaveCompleted (Err (Http.BadStatus 502))) (loadedWith allOff) (Just "test-token")
                    |> modelOf
                    |> Notifications.view
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "and we cannot say why" ]
        ]
