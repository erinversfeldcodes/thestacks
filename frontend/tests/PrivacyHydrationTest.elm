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
import Types.RemoteData exposing (RemoteData(..))


seed : { analytics : Bool, writingAssistant : Bool }
seed =
    { analytics = False, writingAssistant = False }


loadingModel : Privacy.Model
loadingModel =
    Privacy.initWithToken (Just "token") seed |> Tuple.first


hydrated : Api.PrivacySettings
hydrated =
    { profileVisibility = "owner"
    , shelves = []
    , consentAnalytics = False
    , consentWritingAssistant = False
    }


hydratedModel : Privacy.Model
hydratedModel =
    Privacy.update (Privacy.GotPrivacySettings (Ok hydrated)) loadingModel (Just "token")
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
        , test "while the fetch is in flight both consent toggles are disabled" <|
            \_ ->
                Privacy.view loadingModel
                    |> Query.fromHtml
                    |> consentToggles
                    |> Query.each (Query.has [ Selector.disabled True ])
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
        , test "a failed fetch keeps the controls inert rather than editing defaults" <|
            \_ ->
                let
                    failed =
                        Privacy.update
                            (Privacy.GotPrivacySettings (Err (Http.BadStatus 500)))
                            loadingModel
                            (Just "token")
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
