module Page.BlogArchiveTest exposing (suite)

{-| The archive is a cross-author list, so each entry has to say who wrote the
post and show enough of it to be worth opening.

Both were missing, and neither was visible from a test: the app-level mapping
filled `body` with `""` and the summary carried no author at all, so the page
rendered a title, an empty paragraph and no byline — a perfectly well-formed
list of nothing. These tests assert the decoded values reach the record, which
is the layer where that was lost.

-}

import Expect
import Json.Decode as Decode
import Test exposing (Test, describe, test)
import Types.BlogPost exposing (blogPostSummaryDecoder)


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
        ]
