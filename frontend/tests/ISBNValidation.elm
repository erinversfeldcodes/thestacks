module ISBNValidation exposing (suite)

import Components.ISBNInput exposing (isValidISBN, validateISBN10, validateISBN13)
import Expect
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "ISBN Validation"
        [ describe "validateISBN10"
            [ test "valid ISBN-10: 0306406152" <|
                \_ ->
                    validateISBN10 "0306406152"
                        |> Expect.equal True
            , test "valid ISBN-10 with X check digit: 020161622X" <|
                \_ ->
                    validateISBN10 "020161622X"
                        |> Expect.equal True
            , test "invalid ISBN-10: wrong checksum" <|
                \_ ->
                    validateISBN10 "0306406153"
                        |> Expect.equal False
            , test "invalid ISBN-10: wrong length" <|
                \_ ->
                    validateISBN10 "030640615"
                        |> Expect.equal False
            , test "valid ISBN-10 with hyphens: 0-306-40615-2" <|
                \_ ->
                    validateISBN10 "0-306-40615-2"
                        |> Expect.equal True
            ]
        , describe "validateISBN13"
            [ test "valid ISBN-13: 9780306406157" <|
                \_ ->
                    validateISBN13 "9780306406157"
                        |> Expect.equal True
            , test "valid ISBN-13: 9780141036137" <|
                \_ ->
                    validateISBN13 "9780141036137"
                        |> Expect.equal True
            , test "invalid ISBN-13: wrong checksum" <|
                \_ ->
                    validateISBN13 "9780306406158"
                        |> Expect.equal False
            , test "invalid ISBN-13: wrong length" <|
                \_ ->
                    validateISBN13 "978030640615"
                        |> Expect.equal False
            , test "valid ISBN-13 with hyphens: 978-0-306-40615-7" <|
                \_ ->
                    validateISBN13 "978-0-306-40615-7"
                        |> Expect.equal True
            ]
        , describe "isValidISBN"
            [ test "accepts valid ISBN-10" <|
                \_ ->
                    isValidISBN "0306406152"
                        |> Expect.equal True
            , test "accepts valid ISBN-13" <|
                \_ ->
                    isValidISBN "9780306406157"
                        |> Expect.equal True
            , test "rejects empty string" <|
                \_ ->
                    isValidISBN ""
                        |> Expect.equal False
            , test "rejects invalid length" <|
                \_ ->
                    isValidISBN "12345"
                        |> Expect.equal False
            , test "rejects invalid ISBN-10 checksum" <|
                \_ ->
                    isValidISBN "0306406153"
                        |> Expect.equal False
            ]
        ]
