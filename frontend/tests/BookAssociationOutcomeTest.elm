module BookAssociationOutcomeTest exposing (suite)

{-| That the author is told what happened to their association pass.

⛔ THE DEFECT: an empty association list rendered `text ""`, so a post whose
pass failed looked exactly like one that was never tried. Every terminal path in
the worker counts itself under telemetry, which reaches a dashboard and reaches
the author not at all — leaving the writer to guess whether the feature is broken
or their post simply has no books in it.

-}

import Components.BookAssociations
import Expect
import Html exposing (Html)
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.BlogPost as BlogPost exposing (AssociationOutcome(..))


render : Bool -> AssociationOutcome -> Query.Single ()
render isOwner outcome =
    Query.fromHtml (viewWith isOwner outcome)


viewWith : Bool -> AssociationOutcome -> Html ()
viewWith isOwner outcome =
    Components.BookAssociations.view
        { associations = []
        , isOwner = isOwner
        , outcome = outcome
        , onConfirm = always ()
        , onDismiss = always ()
        }


suite : Test
suite =
    describe "what the author is told when no books were linked"
        [ test "a failed pass says so, and says it is not permanent" <|
            \_ ->
                render True Failed
                    |> Query.has [ Selector.text "We couldn't link books to this post this time." ]
        , test "a pass that found nothing says that instead" <|
            \_ ->
                render True FoundNothing
                    |> Query.has [ Selector.text "No books from your shelves came up in this post." ]

        -- ⛔ THE TWO MUST NOT BE THE SAME MESSAGE. A completed scan that found
        -- no books and a scan that could not run are different facts, and the
        -- author can act on one of them.
        , test "the two outcomes do not share their copy" <|
            \_ ->
                render True FoundNothing
                    |> Query.hasNot [ Selector.text "We couldn't link books to this post this time." ]

        -- ⚖️ A draft nobody has scanned yet says nothing at all. Claiming a
        -- result that does not exist would be worse than silence.
        , test "a pass that has not run yet says nothing" <|
            \_ ->
                render True NotRunYet
                    |> Query.hasNot [ Selector.class "book-associations__note" ]

        -- ⚠️ And none of it is shown to a reader who is not the author.
        , test "a reader who is not the author is told nothing" <|
            \_ ->
                render False Failed
                    |> Query.hasNot [ Selector.class "book-associations__note" ]
        , describe "decoding the wire value"
            [ test "the two failure outcomes both read as Failed" <|
                \_ ->
                    Expect.equal
                        [ Failed, Failed ]
                        (List.map BlogPost.fromProtoAssociationOutcome
                            [ "unreadable_response", "llm_error" ]
                        )

            -- ⚠️ An outcome this client has never heard of reads as NotRunYet,
            -- not as Failed: the server growing a case the SPA has not been
            -- taught must not make us claim a failure the author cannot act on.
            , test "an unrecognised outcome is not reported as a failure" <|
                \_ ->
                    Expect.equal
                        NotRunYet
                        (BlogPost.fromProtoAssociationOutcome "something_new")
            ]
        ]
