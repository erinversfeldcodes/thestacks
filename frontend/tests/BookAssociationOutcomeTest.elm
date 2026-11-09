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
import Stacks.Api.V1.BlogResponses as Envelope
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.BlogPost as BlogPost exposing (AssociationOutcome)


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


{-| Render with a surviving association, so the POPULATED path is reachable.

⚖️ Every other case in this file renders with `associations = []`, which could
not reach the populated branch at all — that is how the view consulting the
outcome only inside `List.isEmpty` went unnoticed.

-}
renderWithRows : Bool -> AssociationOutcome -> Query.Single ()
renderWithRows isOwner outcome =
    Query.fromHtml
        (Components.BookAssociations.view
            { associations =
                [ { id = "a1"
                  , bookId = "b1"
                  , bookTitle = "Piranesi"
                  , confidence = 0.9
                  , reasoning = "named twice"
                  , status = BlogPost.Confirmed
                  }
                ]
            , isOwner = isOwner
            , outcome = outcome
            , onConfirm = always ()
            , onDismiss = always ()
            }
        )


staleSentence : String
staleSentence =
    "The latest attempt to find books didn't finish, so these are from an earlier one."


emptySentence : String
emptySentence =
    "We couldn't link books to this post this time."


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
                render True Envelope.AssociationOutcomeUnreadableResponse
                    |> Expect.all
                        [ Query.has [ Selector.class "book-associations__note" ]
                        , Query.has
                            [ Selector.text "We couldn't link books to this post this time." ]
                        ]
        , test "a pass that found nothing says that instead" <|
            \_ ->
                render True Envelope.AssociationOutcomeNoBooksFound
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
                render True Envelope.AssociationOutcomeNoBooksFound
                    |> Query.hasNot [ Selector.text "We couldn't link books to this post this time." ]

        -- ⚖️ A draft nobody has scanned yet says nothing at all. Claiming a
        -- result that does not exist would be worse than silence.
        , test "a pass that has not run yet says nothing" <|
            \_ ->
                render True Envelope.AssociationOutcomeUnspecified
                    |> Query.hasNot [ Selector.class "book-associations__note" ]

        -- ⚠️ And none of it is shown to a reader who is not the author.
        , test "a reader who is not the author is told nothing" <|
            \_ ->
                render False Envelope.AssociationOutcomeUnreadableResponse
                    |> Query.hasNot [ Selector.class "book-associations__note" ]
        , describe "decoding the wire value"
            [ -- ⛔ ONE ASSERTION PER WIRE STRING, because three of the five had
              -- none and a reviewer proved it costs nothing to break them:
              -- rewriting `"associated" -> Envelope.AssociationOutcomeUnspecified` and
              -- `"no_books_found" -> Envelope.AssociationOutcomeUnspecified` — collapsing both successes into
              -- the silence this issue exists to remove — left 2303 passing.
              --
              -- ⚠️ This is the function the issue records as having had three of
              -- four vocabularies disagree on ship day, with both consequences
              -- user-visible and both fixed by hand. Until the proto enum lands
              -- these five assertions are the interim guard, and the component
              -- cases cannot stand in for them: they pass `Envelope.AssociationOutcomeNoBooksFound` as a
              -- CONSTRUCTOR, so nothing connected the wire string
              -- `"no_books_found"` to the copy Requirement 2 asks for.
              test "every wire string the server can send decodes to its own outcome" <|
                \_ ->
                    Expect.equal
                        (Ok
                            [ Envelope.AssociationOutcomeAssociated
                            , Envelope.AssociationOutcomeNoBooksFound
                            , Envelope.AssociationOutcomeUnreadableResponse
                            , Envelope.AssociationOutcomeUnexpectedShape
                            , Envelope.AssociationOutcomeLlmError
                            ]
                        )
                        (decodeOutcomes
                            [ "associated"
                            , "no_books_found"
                            , "unreadable_response"
                            , "unexpected_shape"
                            , "llm_error"
                            ]
                        )

            -- ⬛ AND THE TWO SUCCESSES ARE DISTINCT, asserted separately so a
            -- collapse cannot hide behind a list comparison that happens to
            -- stay the same length.
            , test "a pass that associated is not the same outcome as one that found nothing" <|
                \_ ->
                    Expect.notEqual
                        (decodeOutcomes [ "associated" ])
                        (decodeOutcomes [ "no_books_found" ])

            -- ⚠️ An outcome this build has not been taught decodes to
            -- UNSPECIFIED rather than to a failure: proto3 enums are open, and
            -- claiming a failure the author cannot act on would be worse than
            -- staying quiet about a result we cannot interpret.
            , test "an unrecognised outcome is not reported as a failure" <|
                \_ ->
                    Expect.equal
                        (Ok [ Envelope.AssociationOutcomeUnspecified ])
                        (decodeOutcomes [ "something_new" ])
            ]
        , describe "a failed pass with rows that survived it"
            [ -- ⛔ THE AUTHOR SAW THEIR BOOKS AND WAS NEVER TOLD THE NEWEST PASS
              -- FAILED. Reachable by republishing: no already-published guard,
              -- the worker deletes nothing on a failure branch, and the outcome
              -- reports the newest pass.
              test "the owner is told the latest attempt did not finish" <|
                \_ ->
                    renderWithRows True Envelope.AssociationOutcomeLlmError
                        |> Query.has [ Selector.text staleSentence ]

            -- ⬛ AND THE ROWS ARE STILL THERE — a note that replaced the list
            -- would satisfy the case above while losing the author's books.
            , test "the surviving books are still rendered beside the note" <|
                \_ ->
                    renderWithRows True Envelope.AssociationOutcomeLlmError
                        |> Query.has [ Selector.text "Piranesi" ]

            -- ⚠️ BOTH DIRECTIONS of the copy guard. Two strings that drift into
            -- each other is the same defect in a new place, and the suite
            -- already carries this hazard for the other pair.
            , test "the populated note does not borrow the empty-state sentence" <|
                \_ ->
                    renderWithRows True Envelope.AssociationOutcomeLlmError
                        |> Query.hasNot [ Selector.text emptySentence ]
            , test "the empty state does not borrow the populated sentence" <|
                \_ ->
                    render True Envelope.AssociationOutcomeLlmError
                        |> Query.hasNot [ Selector.text staleSentence ]

            -- ⚖️ `NoBooksFound` is DELIBERATELY silent here. Its list is equally
            -- "from an earlier pass", but it is a completed, correct answer —
            -- the list is simply what the post has. This pins the asymmetry so
            -- it reads as a decision rather than as the oversight above.
            , test "a pass that found nothing says nothing, even with rows present" <|
                \_ ->
                    renderWithRows True Envelope.AssociationOutcomeNoBooksFound
                        |> Query.hasNot [ Selector.text staleSentence ]

            -- ⬛ A reader is never told how the author's pass went.
            , test "a reader is not told the author's pass failed" <|
                \_ ->
                    renderWithRows False Envelope.AssociationOutcomeLlmError
                        |> Query.hasNot [ Selector.text staleSentence ]
            ]
        , describe "the envelope's outcome, in the shapes the server really sends"
            [ -- ⛔ ZERO TESTS MENTIONED THIS KEY AT ALL. `grep -rn
              -- "association_outcome" frontend/tests/` returned nothing, while
              -- the live non-owner payload carried `null` and decoded only
              -- because `decodeAssociationOutcome` opens with `Decode.string`,
              -- which fails on `null`, and a bare `oneOf` fallback swallowed
              -- the failure. The server now OMITS the key; these pin all three
              -- shapes so neither half can drift back.
              test "an absent key reads as Unspecified — the server's real shape" <|
                \_ ->
                    Expect.equal
                        (Ok Envelope.AssociationOutcomeUnspecified)
                        (decodeOutcomeFromEnvelope Nothing)

            -- ⚠️ `null` is NOT a value the enum declares, and is no longer sent
            -- — handled on purpose because a proxy or a non-Elm producer still
            -- could, and the alternative is a whole page failing to decode.
            , test "an explicit null reads as Unspecified, rather than failing the page" <|
                \_ ->
                    Expect.equal
                        (Ok Envelope.AssociationOutcomeUnspecified)
                        (decodeOutcomeFromEnvelope (Just "null"))

            -- ⬛ ANTI-VACUITY: a real outcome must come through as itself, or a
            -- decoder that answered Unspecified to everything would satisfy
            -- both cases above.
            , test "a real outcome on the envelope is not flattened to Unspecified" <|
                \_ ->
                    Expect.equal
                        (Ok Envelope.AssociationOutcomeNoBooksFound)
                        (decodeOutcomeFromEnvelope (Just "\"no_books_found\""))
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
                            , outcome = Envelope.AssociationOutcomeAssociated
                            , onConfirm = always ()
                            , onDismiss = always ()
                            }
                        )
                        |> Query.has [ Selector.text "Piranesi" ]
            ]
        , describe "what the decoder requires, and the one thing it does not"
            [ -- ⛔ THE GUARD PROTECTING THIS ISSUE'S OWN DEFECT WAS UNTESTED.
              -- A reviewer deleted `Decode.succeed []` from the `associations`
              -- arm and the suite still passed 2298/0 — so the decoder written
              -- to stop an absent key becoming an empty list had reproduced
              -- that tolerance one level up, with nothing able to tell.
              --
              -- ⚖️ The four keys the server always sends are now REQUIRED, and
              -- these cases are what makes each decision fail if reversed. Each
              -- had a specific lie waiting behind its default.
              test "an absent associations key is a decode failure, not an empty list" <|
                \_ ->
                    expectDecodeFailure
                        """
                        { "post": { "id": "p", "user_id": "u", "title": "T", "body": "B"
                                  , "visibility": "owner", "created_at": "", "updated_at": ""
                                  , "published_at": "", "syndicated": true } }
                        """

            -- ⚠️ `status` defaulting to `Pending` made every association read
            -- as pending for the owner and VANISH for anyone else, because the
            -- component filters a non-owner's view to `Confirmed` only.
            , test "an association without a status is a decode failure" <|
                \_ ->
                    expectDecodeFailure (envelope [ ( "id", "\"a\"" ), ( "book_id", "\"b\"" ), ( "book_title", "\"T\"" ), ( "confidence", "0.9" ) ])

            -- ⚠️ `confidence` defaulting to `0.0` rendered "0%" with a
            -- low-confidence badge — a number the model never gave.
            , test "an association without a confidence is a decode failure" <|
                \_ ->
                    expectDecodeFailure (envelope [ ( "id", "\"a\"" ), ( "book_id", "\"b\"" ), ( "book_title", "\"T\"" ), ( "status", "\"confirmed\"" ) ])
            , test "an association without a book_title is a decode failure" <|
                \_ ->
                    expectDecodeFailure (envelope [ ( "id", "\"a\"" ), ( "book_id", "\"b\"" ), ( "confidence", "0.9" ), ( "status", "\"confirmed\"" ) ])

            -- ⬛ AND THE ONE GENUINE EXCEPTION. The controller DELETES
            -- `reasoning` for a non-owner rather than blanking it, so its
            -- absence is a real server state. This is the only fallback left,
            -- and it is tested rather than assumed.
            , test "an association without a reasoning still decodes, for a non-owner" <|
                \_ ->
                    let
                        json =
                            envelope
                                [ ( "id", "\"a\"" )
                                , ( "book_id", "\"b\"" )
                                , ( "book_title", "\"Piranesi\"" )
                                , ( "confidence", "0.9" )
                                , ( "status", "\"confirmed\"" )
                                ]
                    in
                    case Decode.decodeString BlogPost.blogPostShowDecoder json of
                        Ok post ->
                            Expect.equal [ "" ] (List.map .reasoning post.associations)

                        Err err ->
                            Expect.fail (Decode.errorToString err)
            ]
        ]


{-| Decode a show response whose `association_outcome` is absent, null, or a value.

⚖️ Through the real `blogPostShowDecoder`, not a hand-rolled one — the defect
these cases exist for lived in how the three arms compose, which a decoder
written for the test would not reproduce.

-}
decodeOutcomeFromEnvelope : Maybe String -> Result Decode.Error AssociationOutcome
decodeOutcomeFromEnvelope rawOutcome =
    let
        outcomeKey =
            case rawOutcome of
                Just raw ->
                    ", \"association_outcome\": " ++ raw

                Nothing ->
                    ""

        json =
            """
            { "post":
                { "id": "p1", "user_id": "u1", "title": "T", "body": "B"
                , "visibility": "owner", "created_at": "", "updated_at": ""
                , "published_at": "", "syndicated": true
                }
            , "associations": []
            """
                ++ outcomeKey
                ++ "}"
    in
    Decode.decodeString BlogPost.blogPostShowDecoder json
        |> Result.map .associationOutcome


{-| Decode a list of wire strings through the GENERATED enum decoder.

⚖️ Through the generated decoder rather than a hand-written mapper, because the
hand-written one is gone — that was the point of the enum. A new outcome on the
contract now regenerates this decoder and breaks the exhaustive `case` in the
component, instead of falling silently to a default.

-}
decodeOutcomes : List String -> Result Decode.Error (List AssociationOutcome)
decodeOutcomes wire =
    wire
        |> List.map (\s -> "\"" ++ s ++ "\"")
        |> List.map (Decode.decodeString Envelope.decodeAssociationOutcome)
        |> List.foldr (Result.map2 (::)) (Ok [])


{-| A show response carrying one association built from the given fields.
-}
envelope : List ( String, String ) -> String
envelope fields =
    let
        assoc =
            fields
                |> List.map (\( k, v ) -> "\"" ++ k ++ "\": " ++ v)
                |> String.join ", "
    in
    """
    { "post": { "id": "p", "user_id": "u", "title": "T", "body": "B"
              , "visibility": "owner", "created_at": "", "updated_at": ""
              , "published_at": "", "syndicated": true }
    , "associations": [ {""" ++ assoc ++ """} ]
    }
    """


expectDecodeFailure : String -> Expect.Expectation
expectDecodeFailure json =
    case Decode.decodeString BlogPost.blogPostShowDecoder json of
        Ok _ ->
            Expect.fail
                "the decoder accepted a payload the server cannot produce — a default for a key that is always sent buys nothing and costs silence"

        Err _ ->
            Expect.pass
