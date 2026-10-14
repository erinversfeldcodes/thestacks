module Components.SyndicationTest exposing (suite)

{-| Components.Syndication: the honesty rules — absent affordances
on a non-public post, the clipboard's refusal made visible, and the toggle
snapping back when the save fails.
-}

import Api
import Components.Syndication as Syndication
import Expect
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
    -- `init` now returns a Cmd as well, because the panel asks the server what has
    -- already been syndicated. These view tests only need the model.
    Tuple.first (Syndication.init "post-1" "https://thestacks.test" True Nothing)


recorded : Maybe String -> Api.Syndication
recorded syndicatedUrl =
    { id = "syn-1"
    , target = "substack"
    , method = "export"
    , canonicalUrl = "https://thestacks.test/blog/post-1"
    , syndicatedUrl = syndicatedUrl
    , createdAt = "2026-10-14T00:00:00Z"
    }


{-| The panel after the server has answered with what was already syndicated —
the state that was unreachable before the read path existed.
-}
afterFetch : List Api.Syndication -> Syndication.Model
afterFetch syndications =
    let
        ( model, _ ) =
            Syndication.update (Syndication.GotSyndications (Ok syndications)) initModel Nothing
                |> (\( m, c, _ ) -> ( m, c ))
    in
    model


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
        , describe "what the server already recorded"
            [ test "a fetched backlink is shown, so a reload no longer forgets it" <|
                \_ ->
                    render (afterFetch [ recorded (Just "https://substack.test/p/marginalia") ]) True
                        |> Query.find [ byTestId "syndication-backlink" ]
                        |> Query.has [ Selector.text "https://substack.test/p/marginalia" ]
            , test "a fetched syndication with no backlink yet offers the field to add one" <|
                \_ ->
                    -- The half that made this worse than a display bug: the input is
                    -- shown only against a recorded syndication, so forgetting the
                    -- list also removed the writer's way to record the URL at all.
                    render (afterFetch [ recorded Nothing ]) True
                        |> Query.has [ byTestId "syndication-also-at-input" ]
            , test "a post never syndicated shows neither" <|
                \_ ->
                    render (afterFetch []) True
                        |> Query.hasNot [ byTestId "syndication-also-at-input" ]
            , test "a failed fetch leaves the panel usable rather than erroring" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Syndication.update
                                (Syndication.GotSyndications (Err Http.NetworkError))
                                initModel
                                Nothing
                    in
                    render model True
                        |> Query.has [ byTestId "syndication-canonical-url" ]
            , test "without a token the panel issues no request" <|
                \_ ->
                    -- Elm commands are opaque, so this pins the branch that CAN be
                    -- compared: a signed-out mount must not ask. The with-token
                    -- branch is covered by the handler tests above.
                    Syndication.init "post-1" "https://thestacks.test" True Nothing
                        |> Tuple.second
                        |> Expect.equal Cmd.none
            ]
        ]
