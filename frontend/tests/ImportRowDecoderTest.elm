module ImportRowDecoderTest exposing (suite)

{-| Decoder tests for a Goodreads import report row.

The report decodes as a `Decode.list`, so ONE row that fails to decode fails the
whole response and the page renders "The report didn't load" — permanently, since
retrying re-fetches the same rows. That is what makes an over-strict field here
different from an over-strict field elsewhere: the blast radius is the entire
report, not one cell.

An unreadable row is the case that bit: `GoodreadsCsv` emits only
`row_number`/`outcome`/`reason` for it, and `insert_all` applies no changeset or
schema default, so `title`, `author`, `isbn13` and `goodreads_shelf` arrive null.

-}

import Api
import Expect
import Json.Decode as Decode
import Test exposing (Test, describe, test)


decode : String -> Result Decode.Error Api.ImportRow
decode =
    Decode.decodeString Api.importRowDecoder


suite : Test
suite =
    describe "importRowDecoder"
        [ test "decodes a fully-populated shelved row" <|
            \_ ->
                case
                    decode """
                    { "row_number": 1, "title": "Dune", "author": "Frank Herbert",
                      "isbn13": "9780441013593", "goodreads_shelf": "read",
                      "outcome": "shelved", "reason": null, "book_id": "b1" }
                    """
                of
                    Ok row ->
                        Expect.all
                            [ \r -> Expect.equal 1 r.rowNumber
                            , \r -> Expect.equal "Dune" r.title
                            , \r -> Expect.equal (Just "shelved") r.outcome
                            ]
                            row

                    Err e ->
                        Expect.fail (Decode.errorToString e)
        , test "an unreadable row decodes with its four null columns as blanks" <|
            \_ ->
                case
                    decode """
                    { "row_number": 7, "title": null, "author": null, "isbn13": null,
                      "goodreads_shelf": null, "outcome": "unreadable",
                      "reason": "row 7 has 3 columns where the header has 24" }
                    """
                of
                    Ok row ->
                        Expect.all
                            [ \r -> Expect.equal "" r.title
                            , \r -> Expect.equal "" r.author
                            , \r -> Expect.equal "" r.isbn13
                            , \r -> Expect.equal (Just "unreadable") r.outcome
                            , \r -> Expect.notEqual Nothing r.reason
                            ]
                            row

                    Err e ->
                        Expect.fail
                            ("an unreadable row must still decode — one of these fails the "
                                ++ "whole report: "
                                ++ Decode.errorToString e
                            )
        , test "the four optional columns may be absent entirely" <|
            \_ ->
                case decode """{ "row_number": 9, "outcome": "unreadable", "reason": "bad" }""" of
                    Ok row ->
                        Expect.equal ( "", "" ) ( row.title, row.author )

                    Err e ->
                        Expect.fail (Decode.errorToString e)
        , test "a row missing row_number is still a decode failure" <|
            \_ ->
                -- The tolerance is deliberate and bounded: a row without its number
                -- cannot be rendered or ordered, so that one stays strict.
                case decode """{ "title": "Dune", "outcome": "shelved" }""" of
                    Ok _ ->
                        Expect.fail "row_number must remain required"

                    Err _ ->
                        Expect.pass
        , test "a wrong-typed row_number is a decode failure" <|
            \_ ->
                case decode """{ "row_number": "1", "outcome": "shelved" }""" of
                    Ok _ ->
                        Expect.fail "row_number must be an int, not a string"

                    Err _ ->
                        Expect.pass
        ]
