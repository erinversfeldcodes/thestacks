module PlacementDecoder exposing (suite)

import Expect
import Json.Decode as Decode
import Test exposing (Test, describe, test)
import Types.Placement exposing (Format(..), placementDecoder)


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


missingRequiredFieldJson : String
missingRequiredFieldJson =
    """
    {
        "id": "placement-004"
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
                            , \p -> Expect.equal 1 p.position
                            , \p -> Expect.equal "2024-01-15T10:00:00Z" p.placedAt
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
                            , \p -> Expect.equal 2 p.position
                            , \p ->
                                case p.book of
                                    Just book ->
                                        Expect.equal "b" book.id

                                    Nothing ->
                                        Expect.fail "Expected book to be present"
                            , \p -> Expect.equal [ Physical, EBook ] p.formats
                            , \p -> Expect.equal (Just 4) p.personalRating
                            , \p -> Expect.equal (Just "Interesting read") p.notes
                            ]
                            placement

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "fails when required fields are missing" <|
            \_ ->
                let
                    result =
                        Decode.decodeString placementDecoder missingRequiredFieldJson
                in
                case result of
                    Ok _ ->
                        Expect.fail "Expected decode failure when position and placed_at are missing"

                    Err _ ->
                        Expect.pass
        ]
