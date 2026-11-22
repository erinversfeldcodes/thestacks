module PrivacyHydrationTest exposing (suite)

{-| The privacy page's controls must wait for the stored settings to load.

Until `GET /api/settings/privacy` answers, the page shows defaults, and the
answer re-seeds every control wholesale — so an edit made before it landed
was silently undone, and a Save that followed wrote the default back as a
success. These pin the contract that makes that race impossible: controls
are inert while the fetch is in flight, live once it has answered, and
untouched for flows that never fetch at all.

-}

import Api
import Expect
import Http
import Page.Settings.Privacy as Privacy
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers
import Types.RemoteData exposing (RemoteData(..))


loadingModel : Privacy.Model
loadingModel =
    Privacy.initWithToken (Just (TestHelpers.creds "token")) |> Tuple.first


hydrated : Api.PrivacySettings
hydrated =
    { profileVisibility = "owner"
    , shelves = []
    , consentAnalytics = False
    , consentWritingAssistant = False
    , consentSearchIndexing = False
    }


hydratedModel : Privacy.Model
hydratedModel =
    Privacy.update (Privacy.GotPrivacySettings (Ok hydrated)) loadingModel (Just (TestHelpers.creds "token"))
        |> (\( m, _, _ ) -> m)


{-| The profile-visibility select is the first on the page; the shelf rows
render one each after it.
-}
profileSelect : Query.Single Privacy.Msg -> Query.Single Privacy.Msg
profileSelect =
    Query.findAll [ Selector.tag "select" ] >> Query.first


consentToggles : Query.Single Privacy.Msg -> Query.Multiple Privacy.Msg
consentToggles =
    Query.findAll [ Selector.class "toggle" ]


suite : Test
suite =
    describe "Privacy — controls wait for the stored settings"
        [ test "opening with a session marks the settings fetch as in flight" <|
            \_ ->
                loadingModel.settings |> Expect.equal Loading
        , test "while the fetch is in flight the visibility select is disabled" <|
            \_ ->
                Privacy.view loadingModel
                    |> Query.fromHtml
                    |> profileSelect
                    |> Query.has [ Selector.disabled True ]
        , test "while the fetch is in flight the consent toggles are disabled" <|
            \_ ->
                Privacy.view loadingModel
                    |> Query.fromHtml
                    |> consentToggles
                    |> Query.each (Query.has [ Selector.disabled True ])
        , test "⛔ while the fetch is in flight the toggles show 'not yet known', not a definite On/Off" <|
            -- ⛔ Planted red for the manufactured-value defect. Before the stored
            -- consent has loaded, the controls must NOT present a recorded
            -- decision — "off" is a definite value and showing it before the
            -- fetch answers is the same defect in a new place, made worse by
            -- save-on-click where the displayed state IS the record. They render
            -- "—". Revert the view's unknown branch (so a locked toggle shows
            -- its default On/Off) and this goes red.
            \_ ->
                Privacy.view loadingModel
                    |> Query.fromHtml
                    |> consentToggles
                    |> Query.each
                        (Expect.all
                            [ Query.has [ Selector.class "toggle--unknown" ]
                            , Query.hasNot [ Selector.class "toggle--on" ]
                            , Query.hasNot [ Selector.class "toggle--off" ]
                            ]
                        )
        , test "once the settings have answered the select is live" <|
            \_ ->
                Privacy.view hydratedModel
                    |> Query.fromHtml
                    |> profileSelect
                    |> Query.has [ Selector.disabled False ]
        , test "once the settings have answered the toggles are live" <|
            \_ ->
                Privacy.view hydratedModel
                    |> Query.fromHtml
                    |> consentToggles
                    |> Query.each (Query.has [ Selector.disabled False ])
        , test "once the settings have answered the toggles present a definite state, not '—'" <|
            -- The positive control for the unknown-state test above: '—' is a
            -- pre-fetch-only rendering, so a hydrated toggle must never show it.
            \_ ->
                Privacy.view hydratedModel
                    |> Query.fromHtml
                    |> consentToggles
                    |> Query.each (Query.hasNot [ Selector.class "toggle--unknown" ])
        , test "a failed fetch keeps the controls inert rather than editing defaults" <|
            \_ ->
                let
                    failed =
                        Privacy.update
                            (Privacy.GotPrivacySettings (Err (Http.BadStatus 500)))
                            loadingModel
                            (Just (TestHelpers.creds "token"))
                            |> (\( m, _, _ ) -> m)
                in
                Privacy.view failed
                    |> Query.fromHtml
                    |> profileSelect
                    |> Query.has [ Selector.disabled True ]
        , test "a flow that never fetches leaves the controls live" <|
            \_ ->
                Privacy.view Privacy.init
                    |> Query.fromHtml
                    |> profileSelect
                    |> Query.has [ Selector.disabled False ]
        ]
