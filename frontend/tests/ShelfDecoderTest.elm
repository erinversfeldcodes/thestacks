module ShelfDecoderTest exposing (suite)

{-| Decoder tests for the new shelf response shape (Issue #151).

These tests verify that the JSON response containing shelves with nested
placements decodes correctly.

These tests are expected to FAIL until the Types.Shelf module with
shelfDecoder and shelvesResponseDecoder are implemented.

-}

import Expect
import Json.Decode as Decode
import Test exposing (Test, describe, test)
import Types.Shelf exposing (shelvesResponseDecoder)


suite : Test
suite =
    describe "Shelf decoder (Issue #151)"
        [ decodesShelfWithEmptyPlacements
        , decodesNestedPlacements
        , failsOnMissingShelves
        ]


decodesShelfWithEmptyPlacements : Test
decodesShelfWithEmptyPlacements =
    test "decodes_shelf_with_empty_placements: decodes a single shelf with no placements" <|
        \() ->
            let
                json =
                    """{"shelves": [{"id": "s1", "position": 0, "placements": []}]}"""

                result =
                    Decode.decodeString shelvesResponseDecoder json
            in
            case result of
                Ok shelves ->
                    Expect.equal 1 (List.length shelves)

                Err err ->
                    Expect.fail (Decode.errorToString err)


decodesNestedPlacements : Test
decodesNestedPlacements =
    test "decodes_nested_placements: decodes placements nested within shelves" <|
        \() ->
            let
                json =
                    """{"shelves": [{"id": "s1", "position": 0, "placements": [{"id": "p1", "position": 1, "book": {"id": "b1", "title": "Test Book", "author": {"id": "a1", "name": "Author"}, "editions": [], "edition_count": 0, "subjects": [], "visibility_tier": "public"}}]}]}"""

                result =
                    Decode.decodeString shelvesResponseDecoder json
            in
            case result of
                Ok shelves ->
                    case shelves of
                        [ shelf ] ->
                            Expect.equal 1 (List.length shelf.placements)

                        _ ->
                            Expect.fail ("Expected 1 shelf, got " ++ String.fromInt (List.length shelves))

                Err err ->
                    Expect.fail (Decode.errorToString err)


failsOnMissingShelves : Test
failsOnMissingShelves =
    test "fails_on_missing_shelves: returns error when shelves key is missing" <|
        \() ->
            let
                json =
                    """{"placements": []}"""

                result =
                    Decode.decodeString shelvesResponseDecoder json
            in
            case result of
                Ok _ ->
                    Expect.fail "Expected decoder to fail on missing shelves key"

                Err _ ->
                    Expect.pass
