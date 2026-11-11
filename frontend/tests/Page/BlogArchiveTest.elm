module Page.BlogArchiveTest exposing (suite)

{-| The archive is a cross-author list, so each entry has to say who wrote the
post and show enough of it to be worth opening.

Both were missing, and neither was visible from a test: the app-level mapping
filled `body` with `""` and the summary carried no author at all, so the page
rendered a title, an empty paragraph and no byline — a perfectly well-formed
list of nothing. These tests assert the decoded values reach the record, which
is the layer where that was lost.

-}

import Api
import Expect
import Http
import Json.Decode as Decode
import Page.Blog.Archive as Archive
import Test exposing (Test, describe, test)
import Types.BlogPost exposing (BlogPostSummary, Visibility(..), blogPostSummaryDecoder)
import Types.RemoteData exposing (RemoteData(..))


summaryJson : String
summaryJson =
    """
    {
        "id": "post-1",
        "title": "A shelf by the window",
        "body": "The light there is wrong for reading and right for everything else.",
        "visibility": "public",
        "created_at": "2026-08-01T09:00:00Z",
        "published_at": "2026-08-01T09:00:00Z",
        "author_display_name": "Ada Reader",
        "author_handle": "ada"
    }
    """


suite : Test
suite =
    describe "blog archive summaries"
        [ test "a summary carries the post's body, so the list can preview it" <|
            \_ ->
                case Decode.decodeString blogPostSummaryDecoder summaryJson of
                    Ok summary ->
                        Expect.equal
                            "The light there is wrong for reading and right for everything else."
                            summary.body

                    Err e ->
                        Expect.fail (Decode.errorToString e)
        , test "a summary names its author, so a cross-author list is not anonymous" <|
            \_ ->
                case Decode.decodeString blogPostSummaryDecoder summaryJson of
                    Ok summary ->
                        Expect.equal (Just "Ada Reader") summary.authorDisplayName

                    Err e ->
                        Expect.fail (Decode.errorToString e)
        , test "an absent author is Nothing, not an empty byline" <|
            \_ ->
                let
                    anonymous =
                        """
                        {
                            "id": "post-2",
                            "title": "Untitled",
                            "body": "…",
                            "visibility": "public",
                            "created_at": "2026-08-01T09:00:00Z"
                        }
                        """
                in
                case Decode.decodeString blogPostSummaryDecoder anonymous of
                    Ok summary ->
                        Expect.equal Nothing summary.authorDisplayName

                    Err e ->
                        Expect.fail (Decode.errorToString e)
        , describe "the preview shown in the list"
            [ test "is bounded, however long the first paragraph is" <|
                \_ ->
                    let
                        -- Markdown does not hard-wrap: a paragraph is ONE line.
                        -- Taking "the first two lines" therefore takes the first
                        -- two paragraphs whole, so a long opening paragraph
                        -- printed the entire thing into the list.
                        wall =
                            String.repeat 60 "sentence after sentence "
                    in
                    Archive.previewOf wall
                        |> String.length
                        |> Expect.atMost 220
            , test "a short post is shown whole, with no ellipsis" <|
                \_ ->
                    Archive.previewOf "A short thought about shelves."
                        |> Expect.equal "A short thought about shelves."
            , test "a truncated preview says it was truncated" <|
                \_ ->
                    Archive.previewOf (String.repeat 60 "sentence after sentence ")
                        |> String.endsWith "…"
                        |> Expect.equal True
            , test "does not cut a word in half" <|
                \_ ->
                    let
                        preview =
                            Archive.previewOf (String.repeat 60 "sentence after sentence ")
                    in
                    preview
                        |> String.dropRight 1
                        |> String.endsWith " "
                        |> Expect.equal False
            , test "collapses the blank line between paragraphs" <|
                \_ ->
                    Archive.previewOf "First paragraph.\n\nSecond paragraph."
                        |> Expect.equal "First paragraph. Second paragraph."
            ]
        , describe "paging the feed"
            -- ⛔ The feed used to read the newest window and stop, with no cursor
            -- at all, so a reader who could not see the newest posts had no way
            -- to reach the older ones they were welcome to read. The server side
            -- is fixed; this is the client half, and its failure mode is the one
            -- that makes a cursor useless — a later page REPLACING the archive
            -- instead of extending it, so the reader paginates in place.
            [ test "the cursor is read off the page, present" <|
                \_ ->
                    Decode.decodeString Api.blogPostPageDecoder
                        """{"posts": [], "next_cursor": "abc123"}"""
                        |> Result.map .nextCursor
                        |> Expect.equal (Ok (Just "abc123"))
            , test "a null cursor is the end of the feed" <|
                \_ ->
                    Decode.decodeString Api.blogPostPageDecoder
                        """{"posts": [], "next_cursor": null}"""
                        |> Result.map .nextCursor
                        |> Expect.equal (Ok Nothing)
            , test "an absent cursor decodes, because the author archive sends none" <|
                \_ ->
                    -- `GET /api/blog/posts?user_id=` is one author's archive and
                    -- does not page, so it omits the field entirely. A decoder
                    -- requiring it would fail that whole response.
                    Decode.decodeString Api.blogPostPageDecoder """{"posts": []}"""
                        |> Result.map .nextCursor
                        |> Expect.equal (Ok Nothing)
            , test "a second page extends the archive rather than replacing it" <|
                \_ ->
                    let
                        ( afterFirst, _ ) =
                            Archive.update
                                (Archive.PostsLoaded (Ok { posts = [ postSummary "a" ], nextCursor = Just "c1" }))
                                initialModel

                        ( afterSecond, _ ) =
                            Archive.update
                                (Archive.PostsLoaded (Ok { posts = [ postSummary "b" ], nextCursor = Nothing }))
                                afterFirst
                    in
                    case afterSecond.posts of
                        Success posts ->
                            Expect.equal [ "a", "b" ] (List.map .id posts)

                        _ ->
                            Expect.fail "the archive is not loaded after two pages"
            , test "the load-more affordance disappears once the cursor does" <|
                \_ ->
                    let
                        ( loaded, _ ) =
                            Archive.update
                                (Archive.PostsLoaded (Ok { posts = [ postSummary "a" ], nextCursor = Nothing }))
                                initialModel
                    in
                    Expect.equal Nothing loaded.nextCursor
            , test "a failed later page keeps the pages already read" <|
                \_ ->
                    -- Collapsing to Failure here would throw away everything the
                    -- reader had scrolled, which is a worse answer than a page
                    -- that simply did not arrive.
                    let
                        ( afterFirst, _ ) =
                            Archive.update
                                (Archive.PostsLoaded (Ok { posts = [ postSummary "a" ], nextCursor = Just "c1" }))
                                initialModel

                        ( afterFailure, _ ) =
                            Archive.update
                                (Archive.PostsLoaded (Err Http.NetworkError))
                                afterFirst
                    in
                    case afterFailure.posts of
                        Success posts ->
                            Expect.equal [ "a" ] (List.map .id posts)

                        _ ->
                            Expect.fail "a failed second page erased the first"
            , test "a failed FIRST page is still a failure" <|
                \_ ->
                    -- Anti-vacuity for the test above: without this, preserving
                    -- state would be satisfied by a page that never reports an
                    -- error at all.
                    let
                        ( failed, _ ) =
                            Archive.update
                                (Archive.PostsLoaded (Err Http.NetworkError))
                                initialModel
                    in
                    case failed.posts of
                        Failure _ ->
                            Expect.pass

                        _ ->
                            Expect.fail "the first page failed and the archive did not say so"
            ]
        ]


initialModel : Archive.Model
initialModel =
    Tuple.first (Archive.init Nothing)


postSummary : String -> BlogPostSummary
postSummary id =
    { id = id
    , title = "Title"
    , body = "Body"
    , visibility = Public
    , published = True
    , insertedAt = "2026-08-01T09:00:00Z"
    , authorDisplayName = Just "Ada Reader"
    , authorHandle = Just "ada"
    }
