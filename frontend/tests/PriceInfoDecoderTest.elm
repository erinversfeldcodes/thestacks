module PriceInfoDecoderTest exposing (suite)

{-| The price decoder and its edition grouping.

Also the consuming test that keeps `Components.PriceInfo`'s type aliases exposed:
`elm-review --fix` narrows an exposing list back down when nothing consumes it, so
the enabling change and its consumer have to land together.

-}

import Components.PriceInfo as PriceInfo
import Expect
import Json.Decode as Decode
import Page.BookDetail as BookDetail
import Test exposing (Test, describe, test)


{-| Shaped after what GET /api/books/:id/prices actually returns: one flat row per
(edition, store).
-}
twoEditionsAtOneStore : String
twoEditionsAtOneStore =
    """
    {"prices": [
      {"book_edition_id": "e1", "isbn": "9780749397050", "format_label": "Paperback",
       "store_id": "s1", "store_name": "Exclusive Books", "price_cents": 40000,
       "currency": "ZAR", "in_stock": true,
       "url": "https://exclusivebooks.co.za/products/9780749397050",
       "scraped_at": "2026-07-28T06:00:00Z"},
      {"book_edition_id": "e2", "isbn": "9788497592581", "format_label": "Paperback",
       "store_id": "s1", "store_name": "Exclusive Books", "price_cents": 41100,
       "currency": "ZAR", "in_stock": true,
       "url": "https://exclusivebooks.co.za/products/9788497592581",
       "scraped_at": "2026-07-28T06:00:00Z"}
    ]}
    """


suite : Test
suite =
    describe "book price decoding"
        [ test "keeps editions of one work distinct" <|
            \_ ->
                -- Exclusive Books carries six ISBNs of The Name of the Rose at
                -- different prices. Collapsing them would show one arbitrary price
                -- as though it were the price of the book.
                case Decode.decodeString BookDetail.pricesDecoder twoEditionsAtOneStore of
                    Ok data ->
                        Expect.equal
                            [ "9780749397050", "9788497592581" ]
                            (List.map .isbn data.editions)

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "converts cents to rand at the edge" <|
            \_ ->
                -- The wire carries cents because that is what shops report; only the
                -- view speaks rand.
                case Decode.decodeString BookDetail.pricesDecoder twoEditionsAtOneStore of
                    Ok data ->
                        Expect.equal
                            [ [ 400.0 ], [ 411.0 ] ]
                            (List.map (\e -> List.map .priceZar e.stores) data.editions)

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "sorts stores cheapest first within an edition" <|
            \_ ->
                let
                    json =
                        """
                        {"prices": [
                          {"isbn": "9780749397050", "format_label": "Paperback",
                           "store_name": "Pricey Books", "price_cents": 45000,
                           "url": "https://a", "scraped_at": "2026-07-28T06:00:00Z"},
                          {"isbn": "9780749397050", "format_label": "Paperback",
                           "store_name": "Cheap Books", "price_cents": 38000,
                           "url": "https://b", "scraped_at": "2026-07-28T06:00:00Z"}
                        ]}
                        """
                in
                case Decode.decodeString BookDetail.pricesDecoder json of
                    Ok data ->
                        Expect.equal
                            [ [ "Cheap Books", "Pricey Books" ] ]
                            (List.map (\e -> List.map .storeName e.stores) data.editions)

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "survives a row missing its optional fields" <|
            \_ ->
                -- store_name is a LEFT JOIN and url is nullable, so both can be
                -- absent. A price is still worth showing without them.
                let
                    json =
                        """{"prices": [{"isbn": "9780749397050", "price_cents": 40000}]}"""
                in
                case Decode.decodeString BookDetail.pricesDecoder json of
                    Ok data ->
                        Expect.equal 1 (List.length data.editions)

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "an empty price list decodes to no editions" <|
            \_ ->
                case Decode.decodeString BookDetail.pricesDecoder """{"prices": []}""" of
                    Ok data ->
                        Expect.equal [] data.editions

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "the exposed aliases are constructible by a caller" <|
            \_ ->
                -- Directly consumes PriceInfo's exposed types, which is what stops
                -- elm-review narrowing the exposing list again.
                let
                    listing : PriceInfo.StoreListing
                    listing =
                        { storeName = "Exclusive Books"
                        , priceZar = 400.0
                        , buyUrl = "https://exclusivebooks.co.za"
                        , trend = ""
                        }

                    edition : PriceInfo.EditionPrices
                    edition =
                        { formatLabel = "Paperback"
                        , isbn = "9780749397050"
                        , stores = [ listing ]
                        }

                    data : PriceInfo.PriceData
                    data =
                        { editions = [ edition ], lastUpdated = "2026-07-28T06:00:00Z" }
                in
                Expect.equal 1 (List.length data.editions)
        ]
