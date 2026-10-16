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


{-| Which refusal the panel is rendering, read as a token rather than as prose.
-}
refusal : String -> Selector.Selector
refusal kind =
    Selector.attribute (Html.Attributes.attribute "data-refusal" kind)


initModel : Syndication.Model
initModel =
    -- `init` now returns a Cmd as well, because the panel asks the server what has
    -- already been syndicated. These view tests only need the model.
    Tuple.first (Syndication.init "post-1" "https://thestacks.test" True Nothing)


recorded : Maybe String -> Api.Syndication
recorded syndicatedUrl =
    recordedAt "syn-1" "2026-10-14T00:00:00Z" syndicatedUrl


recordedAt : String -> String -> Maybe String -> Api.Syndication
recordedAt id createdAt syndicatedUrl =
    { id = id
    , target = "substack"
    , method = "export"
    , canonicalUrl = "https://thestacks.test/blog/post-1"
    , syndicatedUrl = syndicatedUrl
    , createdAt = createdAt
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


{-| A panel with one recorded syndication (so the backlink field is offered) on
which a save has just come back with the given failure.
-}
afterSaveFailure : Http.Error -> Query.Single Syndication.Msg
afterSaveFailure err =
    let
        ( model, _, _ ) =
            Syndication.update
                (Syndication.UrlSaved (Err err))
                (afterFetch [ recorded Nothing ])
                (Just "tok")
    in
    render model True


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
            , describe "a failed backlink save says WHICH failure"
                [ test "422 is the only one that blames the address" <|
                    \_ ->
                        afterSaveFailure (Http.BadStatus 422)
                            |> Query.find [ byTestId "syndication-url-error" ]
                            |> Expect.all
                                [ Query.has [ Selector.text "doesn't look like a web address" ]
                                , Query.has [ refusal "bad-address" ]
                                ]
                , test "an expired session says so, and says the text is still there" <|
                    \_ ->
                        -- All five of these were one message, and the message was
                        -- "that doesn't look like a web address" — so a writer
                        -- whose session had lapsed was invited to retype a URL
                        -- that had never been the problem, as many times as they
                        -- liked.
                        --
                        -- The negative is on `data-refusal`, not on the other
                        -- message's wording: an absence asserted about copy comes
                        -- true the moment the copy is reworded, which is the one
                        -- change most likely to happen to it.
                        afterSaveFailure (Http.BadStatus 401)
                            |> Query.find [ byTestId "syndication-url-error" ]
                            |> Expect.all
                                [ Query.has [ Selector.text "signed out" ]
                                , Query.has [ refusal "signed-out" ]
                                , Query.hasNot [ refusal "bad-address" ]
                                ]
                , test "a vanished post sends the writer to reload, not to retype" <|
                    \_ ->
                        afterSaveFailure (Http.BadStatus 404)
                            |> Query.find [ byTestId "syndication-url-error" ]
                            |> Expect.all
                                [ Query.has [ Selector.text "Reload the page" ]
                                , Query.has [ refusal "gone" ]
                                , Query.hasNot [ refusal "bad-address" ]
                                ]
                , test "a network failure exonerates the address explicitly" <|
                    \_ ->
                        afterSaveFailure Http.NetworkError
                            |> Query.find [ byTestId "syndication-url-error" ]
                            |> Expect.all
                                [ Query.has [ Selector.text "The address is fine" ]
                                , Query.has [ refusal "unreachable" ]
                                , Query.hasNot [ refusal "bad-address" ]
                                ]
                , test "and a successful save shows no error at all" <|
                    \_ ->
                        -- The positive control: four hasNots above are each
                        -- satisfied by a panel that renders no error element,
                        -- which is also what a broken branch would do.
                        render (afterFetch [ recorded Nothing ]) True
                            |> Query.hasNot [ byTestId "syndication-url-error" ]
                ]
            , test "a failed fetch leaves the export working and says it could not check" <|
                \_ ->
                    -- This asserted the canonical-url block, which renders
                    -- unconditionally — so it passed for any model and for any
                    -- rewrite of the branch it was named after. What the branch
                    -- actually protects is that the export still works AND that
                    -- a failed read does not masquerade as "never syndicated".
                    let
                        ( model, _, out ) =
                            Syndication.update
                                (Syndication.GotSyndications (Err Http.NetworkError))
                                initModel
                                Nothing
                    in
                    Expect.all
                        [ \m ->
                            render m True
                                |> Query.has [ byTestId "syndication-export-markdown" ]
                        , \m ->
                            render m True
                                |> Query.has [ byTestId "syndication-read-failed" ]
                        , \_ -> Expect.equal Syndication.NoOut out
                        ]
                        model
            , test "a never-syndicated post does not claim the read failed" <|
                \_ ->
                    render (afterFetch []) True
                        |> Query.hasNot [ byTestId "syndication-read-failed" ]
            , test "a late read does not drop a syndication recorded while it was in flight" <|
                \_ ->
                    -- The POST can land before the mount GET answers. Replacing
                    -- the list would lose the new row and send the backlink PUT
                    -- to an older syndication id — a wrong write.
                    let
                        ( afterRecord, _, _ ) =
                            Syndication.update
                                (Syndication.SyndicationRecorded
                                    (Ok (recordedAt "syn-2" "2026-10-15T00:00:00Z" Nothing))
                                )
                                (afterFetch [ recordedAt "syn-1" "2026-10-14T00:00:00Z" Nothing ])
                                Nothing

                        ( afterLateRead, _, _ ) =
                            Syndication.update
                                (Syndication.GotSyndications
                                    (Ok [ recordedAt "syn-1" "2026-10-14T00:00:00Z" Nothing ])
                                )
                                afterRecord
                                Nothing
                    in
                    Expect.equal [ "syn-1", "syn-2" ]
                        (List.map .id afterLateRead.syndications |> List.sort)
            , test "the backlink is recorded against the newest syndication by time" <|
                \_ ->
                    -- Not by list position. The server returns these oldest-first
                    -- and nothing pins that, so position meaning "newest" is a
                    -- coincidence the wrong write would depend on.
                    let
                        outOfOrder =
                            afterFetch
                                [ recordedAt "syn-new" "2026-10-20T00:00:00Z" Nothing
                                , recordedAt "syn-old" "2026-10-01T00:00:00Z" Nothing
                                ]
                    in
                    Expect.equal (Just "syn-new")
                        (Maybe.map .id (Syndication.latestSyndication outOfOrder))
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
