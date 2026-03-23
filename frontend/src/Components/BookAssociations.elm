module Components.BookAssociations exposing (view)

import Html exposing (Html, button, div, p, span, text)
import Html.Attributes exposing (class, title)
import Html.Events exposing (onClick)
import Types.BlogPost exposing (BookAssociation)


type alias Config msg =
    { associations : List BookAssociation
    , isOwner : Bool
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
        text ""

    else
        div [ class "book-associations" ]
            [ div [ class "book-associations__title" ]
                [ text "Books from my shelves" ]
            , div [ class "book-associations__list" ]
                (List.map (viewAssociation config) visible)
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
