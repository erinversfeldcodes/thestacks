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
import Json.Decode as Decode
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
        [ -- ⛔ THE POSITIVE ASSERTIONS NAME THE CLASS, AND THAT IS WHAT MAKES THE
          -- ABSENCE ASSERTIONS BELOW MEAN ANYTHING.
          --
          -- They used to assert only `Selector.text`, while the `hasNot` cases
          -- asserted `Selector.class "book-associations__note"` — so renaming
          -- that class in the component left all seven green, forever. An
          -- absence assertion anchored to a name nothing else pins is satisfied
          -- by a typo. What caught the rename was `check-orphan-classes.sh`: a
          -- CSS gate doing a test's job by accident.
          test "a failed pass says so, and says it is not permanent" <|
            \_ ->
                render True Failed
                    |> Expect.all
                        [ Query.has [ Selector.class "book-associations__note" ]
                        , Query.has
                            [ Selector.text "We couldn't link books to this post this time." ]
                        ]
        , test "a pass that found nothing says that instead" <|
            \_ ->
                render True FoundNothing
                    |> Expect.all
                        [ Query.has [ Selector.class "book-associations__note" ]
                        , Query.has
                            [ Selector.text "No books from your shelves came up in this post." ]
                        ]

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
        , describe "decoding the show response"
            [ -- ⛔ THE HAPPY PATH COULD NOT RENDER, AND NO TEST COULD SEE IT.
              --
              -- `GET /api/blog/posts/:id` answers `{post: …, associations: […]}`,
              -- but the SPA decoded `Decode.field "post"` alone and then read
              -- `post.associations` — which the generated decoder fills from
              -- INSIDE the post object, defaulting an absent key to `[]`. So the
              -- component was called with an empty list on every load, and the
              -- book list, the confidence badges and the Confirm/Dismiss controls
              -- were unreachable in the running app.
              --
              -- ⚠️ Every other test in this file renders with `associations = []`,
              -- which is the same shape the broken payload produced — so the suite
              -- could not tell "empty because the outcome says so" from "empty
              -- because the payload never carried any".
              test "the sibling associations key reaches the post" <|
                \_ ->
                    let
                        json =
                            """
                            { "post":
                                { "id": "p1", "user_id": "u1", "title": "T", "body": "B"
                                , "visibility": "owner", "created_at": "", "updated_at": ""
                                , "published_at": "", "syndicated": true
                                }
                            , "associations":
                                [ { "id": "a1", "book_id": "b1", "book_title": "Piranesi"
                                  , "confidence": 0.91, "reasoning": "named twice"
                                  , "status": "confirmed"
                                  }
                                ]
                            }
                            """
                    in
                    case Decode.decodeString BlogPost.blogPostShowDecoder json of
                        Ok post ->
                            Expect.equal
                                [ ( "Piranesi", 0.91 ) ]
                                (List.map (\a -> ( a.bookTitle, a.confidence )) post.associations)

                        Err err ->
                            Expect.fail (Decode.errorToString err)

            -- ⬛ AND THE COMPONENT RENDERS IT. The decode alone would not prove
            -- the reader sees anything.
            , test "a real association renders its title, not a note" <|
                \_ ->
                    Query.fromHtml
                        (Components.BookAssociations.view
                            { associations =
                                [ { id = "a1"
                                  , bookId = "b1"
                                  , bookTitle = "Piranesi"
                                  , confidence = 0.91
                                  , reasoning = "named twice"
                                  , status = BlogPost.Confirmed
                                  }
                                ]
                            , isOwner = True
                            , outcome = Associated
                            , onConfirm = always ()
                            , onDismiss = always ()
                            }
                        )
                        |> Query.has [ Selector.text "Piranesi" ]
            ]
        ]
