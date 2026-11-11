module Components.BookAssociations exposing (view)

import Html exposing (Html, button, div, p, span, text)
import Html.Attributes exposing (class, title)
import Html.Events exposing (onClick)
import Stacks.Api.V1.BlogResponses as Envelope
import Types.BlogPost exposing (AssociationOutcome, BookAssociation)


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
            -- ⛔ THE OUTCOME USED TO BE CONSULTED ONLY WHEN THE LIST WAS EMPTY,
            -- so the author was never told a pass had failed whenever earlier
            -- rows survived — the one case where they have most reason to ask,
            -- because they are the one who just triggered it.
            --
            -- Reachable through the public API, not hypothetical: `publish_post/2`
            -- has no already-published guard, so a second publish enqueues a
            -- second pass; the worker never deletes rows on a failure branch;
            -- and `latest_association_outcome/1` reports the NEWEST pass. So
            -- "outcome = a failure, associations = rows from an earlier pass" is
            -- a state an author can produce by republishing.
            (staleFailureNote config
                ++ [ div [ class "book-associations__title" ]
                        [ text "Books from my shelves" ]
                   , div [ class "book-associations__list" ]
                        (List.map (viewAssociation config) visible)
                   ]
            )


{-| A note above a populated list saying the newest pass failed.

⚖️ THIS NOTE IS ABOUT FAILURE, NOT ABOUT STALENESS, and the distinction decides
which outcomes get it. The author needs it because an attempt did not complete
and they may want to retry. `NoBooksFound` is deliberately silent here even
though its list is equally "from an earlier pass": it is a completed, correct
answer, and the list is simply what the post has. Reading that silence as the
same oversight this note fixes would be wrong — it is the opposite, a result
that needs no caveat.

⚠️ Its own copy, not `failureNote`'s. "We couldn't link books to this post this
time." implies there is nothing here, which is accurate above an empty state and
false above a populated one. One sentence cannot be true in both positions, so
there are two — and a test asserts neither drifts into the other's wording.

⛔ "DIDN'T WORK", NOT "DIDN'T FINISH". An earlier version said the attempt
"didn't finish", which is false for two of the three outcomes this covers:
`unreadable_response` and `unexpected_shape` are the model ANSWERING and the
answer being unreadable or the wrong shape — a completed pass with a bad result.
Only `llm_error` plausibly did not finish. So the sentence invited the author to
wait for something that had already concluded, which is the mirror of the error
"this time" exists to avoid: a permanent-sounding message is wrong about the
system, and so is an unfinished-sounding one.

⚖️ And it keeps the first-person voice and the verb "link" from the empty-state
sentence. The operation is linking books, not finding them, and one surface
shifting from "We couldn't…" to "The latest attempt…" reads as two different
authors.

⛔ NEITHER SENTENCE MAY CONTAIN THE OTHER, and that is a constraint on the
WORDS, not a style preference. `Test.Html.Selector.text` is a CONTAINMENT match,
so a stale note reading "We couldn't link books to this post this time. These
are from an earlier pass." would satisfy the empty-state's positive assertion
too, and the `hasNot` guard between them would fail open while reading as
covered. "new books" rather than "books to this post" is what keeps them
disjoint — and the guards now use `exactText`, so the constraint is enforced
rather than remembered.

⬛ Owner only. A reader is never told how the author's pass went, here or
anywhere else.

-}
staleFailureNote : Config msg -> List (Html msg)
staleFailureNote config =
    let
        latestPassFailed =
            case config.outcome of
                Envelope.AssociationOutcomeUnreadableResponse ->
                    True

                Envelope.AssociationOutcomeUnexpectedShape ->
                    True

                Envelope.AssociationOutcomeLlmError ->
                    True

                Envelope.AssociationOutcomeUnspecified ->
                    False

                Envelope.AssociationOutcomeAssociated ->
                    False

                Envelope.AssociationOutcomeNoBooksFound ->
                    False
    in
    if config.isOwner && latestPassFailed then
        [ p [ class "book-associations__stale-note" ]
            [ text "We couldn't link new books this time, so these are from an earlier pass." ]
        ]

    else
        []


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
        -- ⛔ EXHAUSTIVE OVER A GENERATED TYPE, which is the whole point of the
        -- outcome being an enum. This used to match a hand-written sum type
        -- whose `_ ->` catch-all swallowed `unexpected_shape` — a value the
        -- worker records and the database permits — so one of the two failure
        -- cases this component exists for rendered as nothing. Adding an
        -- outcome to the contract now breaks this build instead of changing
        -- nothing.
        case config.outcome of
            Envelope.AssociationOutcomeUnspecified ->
                text ""

            Envelope.AssociationOutcomeAssociated ->
                -- A pass that associated books, and then the author dismissed
                -- every one of them. Saying "we found none" here would
                -- contradict what they just did.
                text ""

            Envelope.AssociationOutcomeNoBooksFound ->
                div [ class "book-associations book-associations--empty" ]
                    [ p [ class "book-associations__note" ]
                        [ text "No books from your shelves came up in this post." ]
                    ]

            Envelope.AssociationOutcomeUnreadableResponse ->
                failureNote

            Envelope.AssociationOutcomeUnexpectedShape ->
                failureNote

            Envelope.AssociationOutcomeLlmError ->
                failureNote


{-| ⚖️ One note for all three failure outcomes, deliberately.

The author can act on "this did not work, and your post is fine". Which of an
unparseable answer, a wrong shape, or a provider error it was is ours to fix and
not theirs to read — but they are separate enum values because the DASHBOARD
needs to tell them apart.

-}
failureNote : Html msg
failureNote =
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
