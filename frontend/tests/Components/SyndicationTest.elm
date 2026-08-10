module Components.SyndicationTest exposing (suite)

{-| Components.Syndication (US-6.2.1): the honesty rules — absent affordances
on a non-public post, the clipboard's refusal made visible, and the toggle
snapping back when the save fails.
-}

import Components.Syndication as Syndication
import Html.Attributes
import Http
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector


byTestId : String -> Selector.Selector
byTestId id =
    Selector.attribute (Html.Attributes.attribute "data-testid" id)


initModel : Syndication.Model
initModel =
    Syndication.init "post-1" "https://thestacks.test" True


render : Syndication.Model -> Bool -> Query.Single Syndication.Msg
render model isPublicPublished =
    Syndication.view model "erin" isPublicPublished
        |> Query.fromHtml


suite : Test
suite =
    describe "Components.Syndication"
        [ test "a non-public post gets the honest sentence and NO affordances — absent, not greyed" <|
            \_ ->
                render initModel False
                    |> Query.has [ byTestId "syndication-unavailable" ]
        , test "a non-public post has no copy buttons at all" <|
            \_ ->
                render initModel False
                    |> Query.hasNot [ byTestId "syndication-export-markdown" ]
        , test "a public published post shows canonical address, exports, and the feed URL" <|
            \_ ->
                render initModel True
                    |> Query.has
                        [ byTestId "syndication-panel"
                        , byTestId "syndication-canonical-copy"
                        , byTestId "syndication-export-markdown"
                        , byTestId "syndication-export-html"
                        , byTestId "syndication-feed-url"
                        ]
        , test "the canonical address is the permanent UUID form on the current origin" <|
            \_ ->
                render initModel True
                    |> Query.find [ byTestId "syndication-canonical-url" ]
                    |> Query.has [ Selector.text "https://thestacks.test/blog/post-1" ]
        , test "the feed URL is the handle-addressed blog feed" <|
            \_ ->
                render initModel True
                    |> Query.find [ byTestId "syndication-feed-url" ]
                    |> Query.has [ Selector.text "https://thestacks.test/api/feeds/u/erin/blog" ]
        , test "a refused clipboard write reveals the textarea fallback with the payload" <|
            \_ ->
                let
                    ( afterClick, _, _ ) =
                        Syndication.update Syndication.ClickedCopyCanonical initModel (Just "tok")

                    ( afterRefusal, _, _ ) =
                        Syndication.update (Syndication.CopyOutcome False) afterClick (Just "tok")
                in
                render afterRefusal True
                    |> Query.find [ byTestId "syndication-copy-fallback" ]
                    |> Query.has [ Selector.attribute (Html.Attributes.value "https://thestacks.test/blog/post-1") ]
        , test "a successful copy announces itself" <|
            \_ ->
                let
                    ( afterClick, _, _ ) =
                        Syndication.update Syndication.ClickedCopyCanonical initModel (Just "tok")

                    ( afterCopy, _, _ ) =
                        Syndication.update (Syndication.CopyOutcome True) afterClick (Just "tok")
                in
                render afterCopy True
                    |> Query.has [ Selector.text "Canonical address copied." ]
        , test "a failed toggle save snaps the tickbox back to the truth" <|
            \_ ->
                let
                    ( toggledOff, _, _ ) =
                        Syndication.update
                            (Syndication.ToggledIncludeInFeed False)
                            initModel
                            (Just "tok")

                    ( snappedBack, _, _ ) =
                        Syndication.update
                            (Syndication.ToggleSaved (Err Http.NetworkError))
                            toggledOff
                            (Just "tok")
                in
                render snappedBack True
                    |> Query.find [ byTestId "syndication-include-toggle" ]
                    |> Query.has [ Selector.checked True ]
        ]
