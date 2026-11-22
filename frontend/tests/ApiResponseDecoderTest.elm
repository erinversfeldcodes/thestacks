module ApiResponseDecoderTest exposing (suite)

{-| The book-detail and confirm response decoders must tell an ABSENT optional
field from a PRESENT-but-malformed one.

`placements` is omitted entirely by the ISBN-keyed book lookup, so its decoder
needs a default for absence. It must NOT reuse that default to paper over a
`placements` that arrives as the wrong shape: `oneOf [ field, succeed [] ]` did
exactly that, turning an unreadable payload into a confidently-empty multi-shelf
row — the "structurally valid but false payload" class, where the decode
succeeds so no error ever surfaces and the lie is indistinguishable from the
truth. An absent key still defaults; a present-but-wrong one must now fail where
it can be seen.

Note on reach: the proto-generated placement element decoder is lenient (every
field is `oneOf [ field, succeed default ]`), so a bad _element_ decodes to a
default-filled placement rather than failing the list. The malformation this
fallback actually swallows is therefore `placements` arriving as the wrong JSON
_type_ — which is what these `refuses` cases drive. The element-level leniency is
the larger "every Api decoder" class and is tracked separately.

-}

import Api
import Dict
import Expect
import Http
import Json.Decode as Decode
import Test exposing (Test, describe, test)


{-| A complete, known-valid book payload, so the only thing under test in each
case is how `placements` is handled.
-}
validBook : String
validBook =
    """{"id":"b1","title":"Test Book","author":{"id":"a1","name":"Author"},"editions":[],"edition_count":0,"subjects":[],"visibility_tier":"public"}"""


goodStatus : String -> Http.Response String
goodStatus body =
    Http.GoodStatus_
        { url = "/api/books/confirm"
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        body


suite : Test
suite =
    describe "Api response decoders: absent vs present-but-malformed optional fields"
        [ bookDetailResponseDecoderTests
        , confirmResponseTests
        ]


bookDetailResponseDecoderTests : Test
bookDetailResponseDecoderTests =
    describe "bookDetailResponseDecoder"
        [ test "an absent placements key defaults to [] (the ISBN lookup omits it)" <|
            \_ ->
                ("{\"book\":" ++ validBook ++ "}")
                    |> Decode.decodeString Api.bookDetailResponseDecoder
                    |> Result.map (.placements >> List.length)
                    |> Expect.equal (Ok 0)
        , test "a present, well-formed placements list decodes" <|
            \_ ->
                ("{\"book\":" ++ validBook ++ ",\"placements\":[{\"id\":\"p1\",\"bookshelf_name\":\"library\"}]}")
                    |> Decode.decodeString Api.bookDetailResponseDecoder
                    |> Result.map (.placements >> List.length)
                    |> Expect.equal (Ok 1)
        , test "refuses a placements field present as the wrong type instead of emptying the row" <|
            \_ ->
                ("{\"book\":" ++ validBook ++ ",\"placements\":\"not-an-array\"}")
                    |> Decode.decodeString Api.bookDetailResponseDecoder
                    |> Expect.err
        ]


confirmResponseTests : Test
confirmResponseTests =
    describe "confirmResponseToResult (POST /api/books/confirm)"
        [ test "an absent placements key yields an empty list, not an error" <|
            \_ ->
                goodStatus ("{\"book\":" ++ validBook ++ ",\"source\":\"catalogue\"}")
                    |> Api.confirmResponseToResult
                    |> Result.map (.placements >> List.length)
                    |> Expect.equal (Ok 0)
        , test "refuses a placements field present as the wrong type instead of emptying the duplicate notice" <|
            \_ ->
                goodStatus ("{\"book\":" ++ validBook ++ ",\"placements\":\"not-an-array\",\"source\":\"catalogue\"}")
                    |> Api.confirmResponseToResult
                    |> Expect.err
        ]
