module Components.PriceInfo exposing (EditionPrices, PriceData, StoreListing, view)

{-| Per-book price information component.

Displays prices grouped by edition/format, sorted lowest first,
with store names, ZAR prices, and external buy links.

Fed from `GET /api/books/:id/prices`, which returns one row per
(edition, store) — shops stock whichever edition they stock, at different
prices, so a work can legitimately show several.

-}

import Html exposing (Html, a, div, h3, h4, p, section, span, text)
import Html.Attributes exposing (attribute, class, href, id, rel, target)
import Types.RemoteData exposing (RemoteData(..))


{-| A single store listing for a book edition.
-}
type alias StoreListing =
    { storeName : String
    , priceZar : Float
    , buyUrl : String
    , trend : String
    }


{-| Prices grouped by edition format.
-}
type alias EditionPrices =
    { formatLabel : String
    , isbn : String
    , stores : List StoreListing
    }


{-| All price data for a book.
-}
type alias PriceData =
    { editions : List EditionPrices
    , lastUpdated : String
    }


{-| Render the price information section for a book.

Takes a RemoteData-wrapped PriceData. `NotAsked` renders the placeholder,
which is still the right state for a book nothing has priced yet.

-}
view : RemoteData e PriceData -> Html msg
view priceData =
    section
        [ class "book-detail__section book-detail__prices"
        , attribute "role" "region"
        , attribute "aria-labelledby" "section-prices"
        ]
        [ h3 [ class "book-detail__section-title", id "section-prices" ]
            [ text "Where to Buy (ZAR)" ]
        , case priceData of
            NotAsked ->
                p [ class "book-detail__prices-empty" ]
                    [ text "No price data yet" ]

            Loading ->
                div [ class "book-detail__prices-loading" ]
                    [ span [ class "spinner" ] []
                    , p [] [ text "Checking prices..." ]
                    ]

            Failure _ ->
                p [ class "book-detail__prices-empty" ]
                    [ text "Could not load prices." ]

            Success data ->
                if List.isEmpty data.editions then
                    p [ class "book-detail__prices-empty" ]
                        [ text "No price data yet" ]

                else
                    div []
                        [ div [ class "book-detail__prices-list" ]
                            (List.map viewEditionPrices data.editions)
                        , p [ class "book-detail__prices-footer" ]
                            [ text ("Prices checked by The Stacks — last updated " ++ data.lastUpdated) ]
                        ]
        ]


viewEditionPrices : EditionPrices -> Html msg
viewEditionPrices edition =
    div [ class "book-detail__price-edition" ]
        [ h4 [ class "book-detail__price-edition-label" ]
            [ text (edition.formatLabel ++ " (" ++ edition.isbn ++ ")") ]
        , div [ class "book-detail__price-stores" ]
            (List.map viewStoreListing (List.sortBy .priceZar edition.stores))
        ]


viewStoreListing : StoreListing -> Html msg
viewStoreListing store =
    div [ class "book-detail__price-store" ]
        [ span [ class "book-detail__price-store-name" ] [ text store.storeName ]
        , span [ class "book-detail__price-amount" ]
            [ text ("R " ++ formatPrice store.priceZar) ]
        , span [ class "book-detail__price-trend" ]
            [ text (trendIndicator store.trend) ]
        , a
            [ class "btn btn--sm btn--secondary book-detail__price-buy"
            , href store.buyUrl
            , target "_blank"
            , rel "noopener noreferrer"
            ]
            [ text "Buy" ]
        ]


trendIndicator : String -> String
trendIndicator trend =
    case trend of
        "up" ->
            "↑"

        "down" ->
            "↓"

        _ ->
            "→"


{-| Format a Float as a ZAR price string with two decimal places.
-}
formatPrice : Float -> String
formatPrice price =
    let
        whole =
            floor price

        cents =
            round ((price - toFloat whole) * 100)

        centsStr =
            if cents < 10 then
                "0" ++ String.fromInt cents

            else
                String.fromInt cents
    in
    String.fromInt whole ++ "." ++ centsStr
