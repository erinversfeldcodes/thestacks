module Components.ReviewSummary exposing (view)

{-| Per-book review summary component.

Displays AI-generated review summaries from multiple sources
(GoodReads, Storygraph, Reddit) with sentiment indicators.

Since the API does not yet return enrichment data for reviews,
this component renders a "Coming soon" placeholder for each source.
When the API is extended, pass real data as props.

-}

import Html exposing (Html, div, h3, p, section, span, text)
import Html.Attributes exposing (attribute, class, id, style)
import Types.RemoteData exposing (RemoteData(..))


{-| A single review source summary from an external platform.
-}
type alias ReviewSource =
    { sourceName : String
    , summary : String
    , sentimentScore : Float
    , rating : Maybe Float
    , lastRefreshed : String
    }


{-| Review data for a book, to be fetched or passed as props.
-}
type alias ReviewData =
    { sources : List ReviewSource
    }


{-| Render the review summary section for a book.

Takes a RemoteData-wrapped ReviewData. When the API does not yet provide
review enrichment, pass NotAsked to show the placeholder.

-}
view : RemoteData e ReviewData -> Html msg
view reviewData =
    section
        [ class "book-detail__section book-detail__reviews"
        , attribute "role" "region"
        , attribute "aria-labelledby" "section-reviews"
        ]
        [ h3 [ class "book-detail__section-title", id "section-reviews" ]
            [ text "What People Think" ]
        , div [ class "book-detail__reviews-grid" ]
            (case reviewData of
                NotAsked ->
                    [ viewSourcePlaceholder "GoodReads" "goodreads"
                    , viewSourcePlaceholder "Storygraph" "storygraph"
                    , viewSourcePlaceholder "Reddit" "reddit"
                    ]

                Loading ->
                    [ div [ class "book-detail__review-loading" ]
                        [ span [ class "spinner" ] []
                        , p [] [ text "Loading reviews..." ]
                        ]
                    ]

                Failure _ ->
                    [ p [ class "book-detail__reviews-empty" ]
                        [ text "Could not load reviews." ]
                    ]

                Success data ->
                    if List.isEmpty data.sources then
                        [ p [ class "book-detail__reviews-empty" ]
                            [ text "No reviews yet" ]
                        ]

                    else
                        List.map viewSourceCard data.sources
            )
        , p [ class "book-detail__ai-label" ]
            [ text "AI-generated summary" ]
        ]


viewSourceCard : ReviewSource -> Html msg
viewSourceCard source =
    div [ class "book-detail__review-card" ]
        [ div [ class "book-detail__review-header" ]
            [ div [ class "book-detail__review-icon" ] []
            , span [ class "book-detail__review-source" ] [ text source.sourceName ]
            ]
        , div [ class "book-detail__review-body" ]
            [ p [ class "book-detail__review-summary" ] [ text source.summary ]
            , viewSentimentBar source.sentimentScore
            , case source.rating of
                Just r ->
                    p [ class "book-detail__review-rating" ]
                        [ text (String.fromFloat r ++ " / 5") ]

                Nothing ->
                    text ""
            , p [ class "book-detail__review-refreshed" ]
                [ text ("Last refreshed: " ++ source.lastRefreshed) ]
            ]
        ]


{-| A colour bar representing sentiment: red (0) to amber (0.5) to green (1.0).
-}
viewSentimentBar : Float -> Html msg
viewSentimentBar score =
    let
        clampedScore =
            clamp 0.0 1.0 score

        colour =
            if clampedScore < 0.35 then
                "#c0392b"

            else if clampedScore < 0.65 then
                "#d4a017"

            else
                "#27ae60"

        widthPercent =
            String.fromFloat (clampedScore * 100) ++ "%"
    in
    div [ class "book-detail__review-sentiment" ]
        [ div
            [ class "book-detail__review-sentiment-track"
            , style "background" "#3a3028"
            , style "border-radius" "4px"
            , style "height" "6px"
            , style "width" "100%"
            ]
            [ div
                [ class "book-detail__review-sentiment-fill"
                , style "background" colour
                , style "height" "100%"
                , style "width" widthPercent
                , style "border-radius" "4px"
                , style "transition" "width 0.3s ease"
                ]
                []
            ]
        ]


{-| Placeholder card for a source when data is not yet available.
-}
viewSourcePlaceholder : String -> String -> Html msg
viewSourcePlaceholder sourceName sourceClass =
    div [ class ("book-detail__review-card book-detail__review-card--" ++ sourceClass) ]
        [ div [ class "book-detail__review-header" ]
            [ div [ class "book-detail__review-icon" ] []
            , span [ class "book-detail__review-source" ] [ text sourceName ]
            ]
        , div [ class "book-detail__review-body" ]
            [ p [ class "stub-notice" ] [ text "Sentiment data coming soon" ]
            ]
        ]


{-| Clamp a float between a minimum and maximum.
-}
clamp : Float -> Float -> Float -> Float
clamp lo hi val =
    max lo (min hi val)
