module PlacementDecoder exposing (suite)

import Expect
import Json.Decode as Decode
import Test exposing (Test, describe, test)
import Types.Bookshelf exposing (Bookshelf(..))
import Types.Placement exposing (Format(..), placementDecoder)


minimalPlacementJson : String
minimalPlacementJson =
    """
    {
        "id": "placement-001",
        "book_id": "book-001",
        "shelf_name": "library",
        "placed_at": "2024-01-15T10:00:00Z"
    }
    """


fullPlacementJson : String
fullPlacementJson =
    """
    {
        "id": "placement-002",
        "book_id": "book-002",
        "shelf_name": "antilibrary",
        "placed_at": "2024-02-01T09:00:00Z",
        "removed_at": "2024-03-01T12:00:00Z",
        "formats": ["physical", "ebook"],
        "personal_rating": 4,
        "notes": "Interesting read"
    }
    """


unknownBookshelfJson : String
unknownBookshelfJson =
    """
    {
        "id": "placement-003",
        "book_id": "book-003",
        "shelf_name": "not_a_real_shelf",
        "placed_at": "2024-01-01T00:00:00Z"
    }
    """


missingRequiredFieldJson : String
missingRequiredFieldJson =
    """
    {
        "id": "placement-004",
        "book_id": "book-004"
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
                            , \p -> Expect.equal "book-001" p.bookId
                            , \p -> Expect.equal Library p.bookshelf
                            , \p -> Expect.equal "2024-01-15T10:00:00Z" p.placedAt
                            , \p -> Expect.equal Nothing p.removedAt
                            , \p -> Expect.equal [] p.formats
                            , \p -> Expect.equal Nothing p.personalRating
                            , \p -> Expect.equal Nothing p.notes
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
                            , \p -> Expect.equal AntiLibrary p.bookshelf
                            , \p -> Expect.equal (Just "2024-03-01T12:00:00Z") p.removedAt
                            , \p -> Expect.equal [ Physical, EBook ] p.formats
                            , \p -> Expect.equal (Just 4) p.personalRating
                            , \p -> Expect.equal (Just "Interesting read") p.notes
                            ]
                            placement

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "decodes all bookshelf variants" <|
            \_ ->
                let
                    decodeShelf shelfStr =
                        Decode.decodeString placementDecoder
                            ("""{"id":"p","book_id":"b","shelf_name":"""
                                ++ "\""
                                ++ shelfStr
                                ++ "\""
                                ++ ""","placed_at":"2024-01-01T00:00:00Z"}"""
                            )
                            |> Result.map .bookshelf

                    results =
                        [ ( "library", Ok Library )
                        , ( "antilibrary", Ok AntiLibrary )
                        , ( "wishlist", Ok WishList )
                        , ( "reading_pile", Ok ReadingPile )
                        , ( "looking_for_home", Ok LookingForHome )
                        ]
                in
                Expect.all
                    (List.map
                        (\( shelfStr, expected ) ->
                            \_ -> Expect.equal expected (decodeShelf shelfStr)
                        )
                        results
                    )
                    ()
        , test "fails on unknown shelf name" <|
            \_ ->
                let
                    result =
                        Decode.decodeString placementDecoder unknownBookshelfJson
                in
                case result of
                    Ok _ ->
                        Expect.fail "Expected decode failure for unknown shelf name"

                    Err _ ->
                        Expect.pass
        , test "fails when required fields are missing" <|
            \_ ->
                let
                    result =
                        Decode.decodeString placementDecoder missingRequiredFieldJson
                in
                case result of
                    Ok _ ->
                        Expect.fail "Expected decode failure when shelf_name and placed_at are missing"

                    Err _ ->
                        Expect.pass
        ]
