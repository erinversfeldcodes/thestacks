module PlacementDecoder exposing (suite)

import Expect
import Json.Decode as Decode
import Test exposing (Test, describe, test)
import Types.Placement as Placement exposing (Format(..), ReadingStatus(..), placementDecoder, placementSummaryDecoder)
import Types.Visibility as Visibility


summaryJson : String
summaryJson =
    """
    {
        "book_id": "bk-1",
        "bookshelf_name": "library",
        "title": "The Bell Jar"
    }
    """


minimalPlacementJson : String
minimalPlacementJson =
    """
    {
        "id": "placement-001",
        "position": 1,
        "placed_at": "2024-01-15T10:00:00Z"
    }
    """


fullPlacementJson : String
fullPlacementJson =
    """
    {
        "id": "placement-002",
        "book": {
            "id": "b",
            "isbn": "9780000000002",
            "title": "A Full Book",
            "cover_image_url": null,
            "page_count": 300,
            "author": { "id": "a1", "name": "Some Author" },
            "visibility_tier": "public"
        },
        "position": 2,
        "placed_at": "2024-02-01T09:00:00Z",
        "formats": ["physical", "ebook"],
        "personal_rating": 4,
        "notes": "Interesting read"
    }
    """


placementWithBookshelfNameJson : String
placementWithBookshelfNameJson =
    """
    {
        "id": "placement-003",
        "position": 1,
        "placed_at": "2024-03-01T12:00:00Z",
        "bookshelf_name": "library",
        "formats": [],
        "personal_rating": null,
        "notes": null
    }
    """


minimalIdOnlyJson : String
minimalIdOnlyJson =
    """
    {
        "id": "placement-004"
    }
    """


missingRequiredFieldJson : String
missingRequiredFieldJson =
    """
    {
        "position": 1
    }
    """


placementWithReadingProgressJson : String
placementWithReadingProgressJson =
    """
    {
        "id": "placement-005",
        "position": 3,
        "placed_at": "2024-04-01T08:00:00Z",
        "reading_status": "reading",
        "current_page": 120,
        "started_at": "2024-04-02T09:00:00Z"
    }
    """


suite : Test
suite =
    describe "Placement JSON decoder"
        [ test "decodes minimal placement payload" <|
            \_ ->
                let
                    result =
                        Decode.decodeString placementDecoder minimalPlacementJson
                in
                case result of
                    Ok placement ->
                        Expect.all
                            [ \p -> Expect.equal "placement-001" p.id
                            , \p -> Expect.equal Nothing p.book
                            , \p -> Expect.equal (Just 1) p.position
                            , \p -> Expect.equal (Just "2024-01-15T10:00:00Z") p.placedAt
                            , \p -> Expect.equal [] p.formats
                            , \p -> Expect.equal Nothing p.personalRating
                            , \p -> Expect.equal Nothing p.notes
                            , \p -> Expect.equal Nothing p.bookshelfName
                            , \p -> Expect.equal Nothing p.readingStatus
                            , \p -> Expect.equal Nothing p.currentPage
                            , \p -> Expect.equal Nothing p.startedAt
                            , \p -> Expect.equal Nothing p.finishedAt
                            ]
                            placement

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "decodes full placement payload" <|
            \_ ->
                let
                    result =
                        Decode.decodeString placementDecoder fullPlacementJson
                in
                case result of
                    Ok placement ->
                        Expect.all
                            [ \p -> Expect.equal "placement-002" p.id
                            , \p -> Expect.equal (Just 2) p.position
                            , \p ->
                                case p.book of
                                    Just book ->
                                        Expect.equal "b" book.id

                                    Nothing ->
                                        Expect.fail "Expected book to be present"
                            , \p -> Expect.equal [ Physical, EBook ] p.formats
                            , \p -> Expect.equal (Just 4) p.personalRating
                            , \p -> Expect.equal (Just "Interesting read") p.notes
                            , \p -> Expect.equal Nothing p.bookshelfName
                            ]
                            placement

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "decodes placement with bookshelf_name" <|
            \_ ->
                let
                    result =
                        Decode.decodeString placementDecoder placementWithBookshelfNameJson
                in
                case result of
                    Ok placement ->
                        Expect.all
                            [ \p -> Expect.equal "placement-003" p.id
                            , \p -> Expect.equal (Just "library") p.bookshelfName
                            ]
                            placement

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "decodes placement with only id (optional fields default to Nothing)" <|
            \_ ->
                let
                    result =
                        Decode.decodeString placementDecoder minimalIdOnlyJson
                in
                case result of
                    Ok placement ->
                        Expect.all
                            [ \p -> Expect.equal "placement-004" p.id
                            , \p -> Expect.equal Nothing p.position
                            , \p -> Expect.equal Nothing p.placedAt
                            ]
                            placement

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "missing id defaults to empty string (proto3 resilience)" <|
            \_ ->
                let
                    result =
                        Decode.decodeString placementDecoder missingRequiredFieldJson
                in
                case result of
                    Ok placement ->
                        Expect.equal "" placement.id

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "decodes reading progress fields" <|
            \_ ->
                let
                    result =
                        Decode.decodeString placementDecoder placementWithReadingProgressJson
                in
                case result of
                    Ok placement ->
                        Expect.all
                            [ \p -> Expect.equal "placement-005" p.id
                            , \p -> Expect.equal (Just Reading) p.readingStatus
                            , \p -> Expect.equal (Just 120) p.currentPage
                            , \p -> Expect.equal (Just "2024-04-02T09:00:00Z") p.startedAt
                            , \p -> Expect.equal Nothing p.finishedAt
                            ]
                            placement

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , describe "placementSummaryDecoder (GET /api/placements/mine)"
            [ test "builds a stub book carrying the real book_id + title" <|
                \_ ->
                    case Decode.decodeString placementSummaryDecoder summaryJson of
                        Ok placement ->
                            Expect.all
                                [ \p ->
                                    Expect.equal (Just "bk-1")
                                        (p.book |> Maybe.map .id)
                                , \p ->
                                    Expect.equal (Just "The Bell Jar")
                                        (p.book |> Maybe.map .title)
                                , \p -> Expect.equal (Just "library") p.bookshelfName
                                ]
                                placement

                        Err err ->
                            Expect.fail (Decode.errorToString err)
            ]
        , describe "visibility is parsed at the boundary, not carried as a string"
            [ test "a wire visibility becomes a Visibility" <|
                \_ ->
                    decodedVisibility """{"id":"p-1","visibility":"owner"}"""
                        |> Expect.equal (Ok (Just Visibility.Owner))
            , test "every level the server can send round-trips" <|
                \_ ->
                    [ "owner", "group", "platform", "public" ]
                        |> List.map
                            (\level ->
                                decodedVisibility
                                    ("{\"id\":\"p-1\",\"visibility\":\"" ++ level ++ "\"}")
                            )
                        |> Expect.equalLists
                            [ Ok (Just Visibility.Owner)
                            , Ok (Just Visibility.Group)
                            , Ok (Just Visibility.Platform)
                            , Ok (Just Visibility.Public)
                            ]
            , test "an absent visibility is Nothing" <|
                \_ ->
                    decodedVisibility """{"id":"p-1"}"""
                        |> Expect.equal (Ok Nothing)
            , test "a visibility the client does not recognise is Nothing, not a silent mis-classification" <|
                \_ ->
                    decodedVisibility """{"id":"p-1","visibility":"onwer"}"""
                        |> Expect.equal (Ok Nothing)
            ]
        , describe "isHidden — one reader of the owner-only rule"
            [ test "an owner-only placement is hidden" <|
                \_ ->
                    decodedPlacement """{"id":"p-1","visibility":"owner"}"""
                        |> Result.map Placement.isHidden
                        |> Expect.equal (Ok True)
            , test "a platform placement is not hidden" <|
                \_ ->
                    decodedPlacement """{"id":"p-1","visibility":"platform"}"""
                        |> Result.map Placement.isHidden
                        |> Expect.equal (Ok False)
            , test "a placement with no visibility is not hidden" <|
                \_ ->
                    decodedPlacement """{"id":"p-1"}"""
                        |> Result.map Placement.isHidden
                        |> Expect.equal (Ok False)
            , test "an unrecognised visibility is not hidden (it is not owner)" <|
                \_ ->
                    decodedPlacement """{"id":"p-1","visibility":"onwer"}"""
                        |> Result.map Placement.isHidden
                        |> Expect.equal (Ok False)
            ]
        ]


decodedPlacement : String -> Result Decode.Error Placement.Placement
decodedPlacement json =
    Decode.decodeString placementDecoder json


decodedVisibility : String -> Result Decode.Error (Maybe Visibility.Visibility)
decodedVisibility json =
    decodedPlacement json |> Result.map .visibility
