module Components.BookAssociations exposing (view)

import Html exposing (Html, button, div, p, span, text)
import Html.Attributes exposing (class, title)
import Html.Events exposing (onClick)
import Types.BlogPost exposing (AssociationOutcome(..), BookAssociation)


type alias Config msg =
    { associations : List BookAssociation
    , isOwner : Bool
    , outcome : AssociationOutcome
    , onConfirm : String -> msg
    , onDismiss : String -> msg
    }


view : Config msg -> Html msg
view config =
    let
        visible =
            if config.isOwner then
                config.associations

            else
                List.filter (\a -> a.status == Types.BlogPost.Confirmed) config.associations
    in
    if List.isEmpty visible then
        viewNoAssociations config

    else
        div [ class "book-associations" ]
            [ div [ class "book-associations__title" ]
                [ text "Books from my shelves" ]
            , div [ class "book-associations__list" ]
                (List.map (viewAssociation config) visible)
            ]


{-| ⛔ The author used to be told nothing at all.

An empty list rendered `text ""`, so a post whose association pass failed looked
exactly like one that was never tried — and the writer was left to guess whether
the feature was broken or their post simply had no books in it. Every terminal
path in the worker counts itself under telemetry, which reaches a dashboard and
reaches the author not at all.

⚖️ Only the owner sees any of this. A reader looking at someone else's post has
no use for "we could not link books to this post", and silence is the right
answer for them.

-}
viewNoAssociations : Config msg -> Html msg
viewNoAssociations config =
    if not config.isOwner then
        text ""

    else
        case config.outcome of
            NotRunYet ->
                text ""

            Associated ->
                -- A pass that associated books, and then the author dismissed
                -- every one of them. Saying "we found none" here would
                -- contradict what they just did.
                text ""

            FoundNothing ->
                div [ class "book-associations book-associations--empty" ]
                    [ p [ class "book-associations__note" ]
                        [ text "No books from your shelves came up in this post." ]
                    ]

            Failed ->
                div [ class "book-associations book-associations--failed" ]
                    [ p [ class "book-associations__note" ]
                        -- ⚖️ "this time", because the worker is retryable and
                        -- the author's post is fine. A permanent-sounding
                        -- message would be wrong about the system.
                        [ text "We couldn't link books to this post this time." ]
                    ]


viewAssociation : Config msg -> BookAssociation -> Html msg
viewAssociation config assoc =
    div [ class "book-associations__item" ]
        [ div [ class "book-associations__book" ]
            [ span [ class "book-associations__book-title" ]
                [ text assoc.bookTitle ]
            , viewConfidenceBadge assoc.confidence
            ]
        , if config.isOwner then
            div [ class "book-associations__details" ]
                [ p [ class "book-associations__reasoning" ]
                    [ text assoc.reasoning ]
                , viewStatusBadge assoc.status
                , div [ class "book-associations__actions" ]
                    [ button
                        [ class "btn btn--small btn--confirm"
                        , onClick (config.onConfirm assoc.id)
                        ]
                        [ text "Confirm" ]
                    , button
                        [ class "btn btn--small btn--dismiss"
                        , onClick (config.onDismiss assoc.id)
                        ]
                        [ text "Dismiss" ]
                    ]
                ]

          else
            text ""
        ]


viewConfidenceBadge : Float -> Html msg
viewConfidenceBadge confidence =
    let
        pct =
            String.fromInt (round (confidence * 100))

        badgeClass =
            if confidence >= 0.8 then
                "confidence-badge confidence-badge--high"

            else if confidence >= 0.5 then
                "confidence-badge confidence-badge--medium"

            else
                "confidence-badge confidence-badge--low"
    in
    span [ class badgeClass, title ("Confidence: " ++ pct ++ "%") ]
        [ text (pct ++ "%") ]


viewStatusBadge : Types.BlogPost.AssociationStatus -> Html msg
viewStatusBadge status =
    let
        ( label, badgeClass ) =
            case status of
                Types.BlogPost.Pending ->
                    ( "Pending", "status-badge status-badge--pending" )

                Types.BlogPost.Confirmed ->
                    ( "Confirmed", "status-badge status-badge--confirmed" )

                Types.BlogPost.Dismissed ->
                    ( "Dismissed", "status-badge status-badge--dismissed" )
    in
    span [ class badgeClass ] [ text label ]
