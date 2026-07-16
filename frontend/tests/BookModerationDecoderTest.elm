module BookModerationDecoderTest exposing (suite)

{-| Decoder tests for the owner book-moderation admin list payload (#118).
-}

import Api
import Expect
import Json.Decode as Decode
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "AdminBooksResponse decoder"
        [ test "decodes a paginated book list payload including an age-gated book" <|
            \_ ->
                let
                    json =
                        """
                        {
                          "books": [
                            { "id": "b1", "title": "Dune", "author": "Frank Herbert",
                              "visibility_tier": "age_gated",
                              "isbn": "9780441013593",
                              "cover_image_url": "https://example.com/dune.jpg" },
                            { "id": "b2", "title": "Neuromancer", "author": "William Gibson",
                              "visibility_tier": "public",
                              "isbn": null, "cover_image_url": null }
                          ],
                          "total": 2,
                          "page": 1,
                          "per_page": 50
                        }
                        """
                in
                case Decode.decodeString Api.adminBooksResponseDecoder json of
                    Ok response ->
                        Expect.all
                            [ \r -> Expect.equal 2 (List.length r.books)
                            , \r -> Expect.equal 2 r.total
                            , \r -> Expect.equal 1 r.page
                            , \r -> Expect.equal 50 r.perPage
                            , \r ->
                                r.books
                                    |> List.head
                                    |> Maybe.map .visibilityTier
                                    |> Expect.equal (Just "age_gated")
                            , \r ->
                                r.books
                                    |> List.head
                                    |> Maybe.map .author
                                    |> Expect.equal (Just "Frank Herbert")
                            ]
                            response

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "defaults per_page to 50 when omitted" <|
            \_ ->
                let
                    json =
                        """{ "books": [], "total": 0, "page": 1 }"""
                in
                case Decode.decodeString Api.adminBooksResponseDecoder json of
                    Ok response ->
                        Expect.equal 50 response.perPage

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        ]
