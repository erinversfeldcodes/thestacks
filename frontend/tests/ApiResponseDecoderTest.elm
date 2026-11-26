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

The same `absent-vs-malformed` distinction applies to `my_writing` on
`bookDetailResponseDecoder` and `next_cursor` on `blogPostPageDecoder`. Both used
to default a present-but-malformed value to empty — `oneOf [ field, succeed [] ]`
hid a reader's writing behind "you haven't written about this book yet", and
`Decode.maybe` read a malformed cursor as the end of the discovery feed. Unlike
the placement element decoder, the hand-rolled `myWritingDecoder` requires a
string `id` and `title`, so a bad _element_ (not only a wrong list type) fails —
which is the exact shape these `refuses` cases drive.

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
        , blogPostPageDecoderTests
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
        , test "an absent my_writing key defaults to [] (the ISBN lookup omits it)" <|
            \_ ->
                ("{\"book\":" ++ validBook ++ "}")
                    |> Decode.decodeString Api.bookDetailResponseDecoder
                    |> Result.map (.myWriting >> List.length)
                    |> Expect.equal (Ok 0)
        , test "a present, well-formed my_writing list decodes" <|
            \_ ->
                ("{\"book\":" ++ validBook ++ ",\"my_writing\":[{\"id\":\"w1\",\"title\":\"A post\",\"published_at\":null,\"publication_state\":\"draft\"}]}")
                    |> Decode.decodeString Api.bookDetailResponseDecoder
                    |> Result.map (.myWriting >> List.length)
                    |> Expect.equal (Ok 1)
        , test "refuses a my_writing entry missing its id instead of hiding the reader's writing" <|
            \_ ->
                ("{\"book\":" ++ validBook ++ ",\"my_writing\":[{\"title\":\"A post with no id\"}]}")
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


{-| `next_cursor` is the discovery feed's sole end-of-feed signal, so a malformed
one read as `Nothing` is indistinguishable from the truthful end of the corpus.
The server emits a string (more pages), JSON `null` (end of the discovery corpus),
or omits the key entirely (the single-author archive, which does not page) — all
three must still decode, and only a present value that is neither a string nor
`null` may fail. `Decode.maybe` swallowed that malformed value into `Nothing`.
-}
blogPostPageDecoderTests : Test
blogPostPageDecoderTests =
    describe "blogPostPageDecoder"
        [ test "an absent next_cursor key defaults to Nothing (the single-author archive omits it)" <|
            \_ ->
                "{\"posts\":[]}"
                    |> Decode.decodeString Api.blogPostPageDecoder
                    |> Result.map .nextCursor
                    |> Expect.equal (Ok Nothing)
        , test "a null next_cursor decodes to Nothing (the end of the discovery corpus)" <|
            \_ ->
                "{\"posts\":[],\"next_cursor\":null}"
                    |> Decode.decodeString Api.blogPostPageDecoder
                    |> Result.map .nextCursor
                    |> Expect.equal (Ok Nothing)
        , test "a string next_cursor decodes to Just the cursor" <|
            \_ ->
                "{\"posts\":[],\"next_cursor\":\"cursor-token\"}"
                    |> Decode.decodeString Api.blogPostPageDecoder
                    |> Result.map .nextCursor
                    |> Expect.equal (Ok (Just "cursor-token"))
        , test "refuses a next_cursor present as the wrong type instead of reading it as the end of the feed" <|
            \_ ->
                "{\"posts\":[],\"next_cursor\":42}"
                    |> Decode.decodeString Api.blogPostPageDecoder
                    |> Expect.err
        ]
