module Page.UploadProgramTest exposing (suite)

{-| Program tests for Page.Upload using elm-program-test.

These tests exercise the full Upload page lifecycle through
simulated user interactions and SSE stream events (replacing the old HTTP polling).

-}

import Api exposing (PollStatus(..))
import Dict
import Expect
import Html.Attributes
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Page.Upload as Upload exposing (Msg(..))
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers
    exposing
        ( simulateBookDetailResponseWithPlacements
        , simulateBookResponse
        , simulateConfirmMergeRequiredResponse
        , simulateConfirmResponse
        , simulateMergeFormatResponse
        , testBook
        , uploadProgram
        )


{-| Helper to start an upload program with an auth token and age-gating ON
(ADR-020). Most flows are age-gating-agnostic; the flag-off behaviour is
covered explicitly by `uploadAdultsOnlyHiddenWhenFlagOff`.
-}
startUpload : ProgramTest.ProgramTest Upload.Model Upload.Msg (ProgramTest.SimulatedEffect Upload.Msg)
startUpload =
    ProgramTest.start () (uploadProgram True (Just "test-token"))


{-| Helper to start an upload program with age-gating OFF (the production
default), used to prove age UI is hidden.
-}
startUploadAgeGatingOff : ProgramTest.ProgramTest Upload.Model Upload.Msg (ProgramTest.SimulatedEffect Upload.Msg)
startUploadAgeGatingOff =
    ProgramTest.start () (uploadProgram False (Just "test-token"))


{-| Build an SSE frame exactly as the server emits it.

The one and only wire shape is `StacksWeb.ProtoJSON.poll_response/1`
(`apps/core/lib/stacks_web/proto_json.ex:525-534`), declared by
`proto/stacks/common/v1/upload.proto`'s `PollResponse`: snake\_case, and always
all six keys — `book_ids` defaults to `[]` and `is_duplicate` to `false`
server-side, and `book_id` / `rejection_reason` arrive as JSON `null` rather
than going missing (`UploadController.sse_receive_loop/4` passes all six on
every branch).

These fixtures spoke camelCase until Issue #328, so they exercised a decoder
branch the server never reaches — breaking every production wire field left the
whole Elm suite green.

-}
simulateStreamEvent : PollStatus -> Maybe String -> Bool -> String
simulateStreamEvent status maybeBookId isDuplicate =
    let
        statusStr =
            case status of
                Pending ->
                    "pending"

                Resolved ->
                    "resolved"

                Rejected ->
                    "rejected"

        ( bookId, bookIds ) =
            case maybeBookId of
                Just bid ->
                    ( Encode.string bid, [ bid ] )

                Nothing ->
                    ( Encode.null, [] )
    in
    Encode.encode 0
        (Encode.object
            [ ( "image_id", Encode.string "img-test-001" )
            , ( "status", Encode.string statusStr )
            , ( "book_id", bookId )
            , ( "book_ids", Encode.list Encode.string bookIds )
            , ( "rejection_reason", Encode.null )
            , ( "is_duplicate", Encode.bool isDuplicate )
            ]
        )


{-| The same server frame (`proto_json.ex:525-534`) for a multi-book resolve:
`book_ids` carries the candidates and `book_id` stays null.
-}
simulateMultiBookStreamEvent : List String -> String
simulateMultiBookStreamEvent bookIds =
    Encode.encode 0
        (Encode.object
            [ ( "image_id", Encode.string "img-test-001" )
            , ( "status", Encode.string "resolved" )
            , ( "book_id", Encode.null )
            , ( "book_ids", Encode.list Encode.string bookIds )
            , ( "rejection_reason", Encode.null )
            , ( "is_duplicate", Encode.bool False )
            ]
        )


{-| Build a book HTTP response carrying a specific `visibility_tier`
field. Used to test the age-gated flow where the upload-time book
fetch returns `visibility_tier: "age_gated"` and the verify step
should surface an age-gate notice with a CTA to age verification.
-}
simulateBookWithVisibilityTier : String -> String -> String -> String -> Http.Response String
simulateBookWithVisibilityTier bookId title authorName visibilityTier =
    let
        json =
            Encode.encode 0
                (Encode.object
                    [ ( "book"
                      , Encode.object
                            [ ( "id", Encode.string bookId )
                            , ( "title", Encode.string title )
                            , ( "author"
                              , Encode.object
                                    [ ( "id", Encode.string "author-1" )
                                    , ( "name", Encode.string authorName )
                                    ]
                              )
                            , ( "editions", Encode.list identity [] )
                            , ( "edition_count", Encode.int 0 )
                            , ( "subjects", Encode.list Encode.string [] )
                            , ( "visibility_tier", Encode.string visibilityTier )
                            ]
                      )
                    , ( "placement", Encode.null )
                    ]
                )
    in
    Http.GoodStatus_
        { url = "/api/books/" ++ bookId
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        json


{-| Build a book HTTP response with a specific edition count.
Allows testing edition count logic after merge.
-}
simulateBookWithEditionCount : String -> String -> String -> Int -> Http.Response String
simulateBookWithEditionCount bookId title authorName editionCount =
    let
        json =
            Encode.encode 0
                (Encode.object
                    [ ( "book"
                      , Encode.object
                            [ ( "id", Encode.string bookId )
                            , ( "title", Encode.string title )
                            , ( "author"
                              , Encode.object
                                    [ ( "id", Encode.string "author-1" )
                                    , ( "name", Encode.string authorName )
                                    ]
                              )
                            , ( "editions", Encode.list identity [] )
                            , ( "edition_count", Encode.int editionCount )
                            , ( "subjects", Encode.list Encode.string [] )
                            , ( "visibility_tier", Encode.string "public" )
                            ]
                      )
                    , ( "placement", Encode.null )
                    ]
                )
    in
    Http.GoodStatus_
        { url = "/api/books/" ++ bookId
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        json


{-| Simulate a file being selected and upload accepted.
Since File is an opaque type that cannot be constructed in pure Elm,
we directly send the UploadAccepted message to represent a successful
upload completing.
-}
simulateUploadAccepted :
    ProgramTest.ProgramTest Upload.Model Upload.Msg (ProgramTest.SimulatedEffect Upload.Msg)
    -> ProgramTest.ProgramTest Upload.Model Upload.Msg (ProgramTest.SimulatedEffect Upload.Msg)
simulateUploadAccepted =
    ProgramTest.update (UploadAccepted (Ok "img-test-001"))


suite : Test
suite =
    describe "Page.Upload (ProgramTest)"
        [ uploadHappyPath
        , uploadIsbnRejection
        , uploadNotABook
        , uploadPollTimeout
        , uploadPollTimeoutViaLimit
        , uploadDuplicateDetected
        , uploadManualIsbnEntry
        , uploadManualIsbnValidation
        , uploadMultiBook
        , uploadMultiBookPartialFailure
        , uploadAgeGated
        , uploadMergeFormatSuccess
        , uploadMergeFormatFailure
        , uploadReset
        , uploadDragOver
        , uploadRejectIdentificationRetries
        , uploadAdultsOnly
        , uploadAdultsOnlyHiddenWhenFlagOff
        , manualIsbnDuplicateNoticeInformsWithoutBlocking
        , manualIsbnNoNoticeForABookYouDoNotOwn
        , manualIsbnNewBookIsCreatedThroughConfirm
        , manualIsbnSameWorkOffersMerge
        , manualIsbnAlreadyOnThatShelfSaysSo
        , manualIsbnHonoursTheChosenShelf
        , photoPathDuplicateNoticeInformsWithoutBlocking
        ]


{-| #343 — the wave's headline, and the acceptance test for it.

`9780156453806` is checksum-valid and is NOT in the catalogue. Against the DIY
flow this ISBN was a dead end: `SubmitManualIsbn` issued
`GET /api/books/isbn/9780156453806`, which only ever consults
`Books.find_existing/1`, so a valid ISBN the platform had never seen came back
404 and the reader was told to "check the ISBN and try again" — for a number
that was correct. `Books.confirm/2` resolves it externally, creates the work
and its primary edition, and places it, all in one transaction; it simply had
no caller.

The assertion is therefore about the REQUEST, not only the rendering: the
manual path must dispatch `POST /api/books/confirm`. Simulating a response for
a request the program never made is what fails here on the old flow.

-}
manualIsbnNewBookIsCreatedThroughConfirm : Test
manualIsbnNewBookIsCreatedThroughConfirm =
    test "manual_isbn_new_book: a checksum-valid ISBN absent from the catalogue is created and placed via POST /api/books/confirm" <|
        \() ->
            startUpload
                |> ProgramTest.update EnterManualMode
                |> ProgramTest.update (ManualIsbnChanged "9780156453806")
                |> ProgramTest.update SubmitManualIsbn
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/books/confirm"
                    (simulateConfirmResponse
                        { statusCode = 201
                        , bookId = "book-new-1"
                        , title = "The Book of Disquiet"
                        , authorName = "Fernando Pessoa"
                        , source = Nothing
                        , placements = [ { placementId = "pl-1", bookshelfName = "wishlist" } ]
                        }
                    )
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-complete") ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "\"The Book of Disquiet\" added to Wish List" ]


{-| #333, re-driven over the wired path (#343).

The manual add now goes through `POST /api/books/confirm`, which places the
book and reports every bookshelf the reader has it on. The duplicate awareness
survives the rewiring — and the ruling's point survives with it: the notice
INFORMS. It appears alongside a completed add, not instead of one. The flow
reached its terminal screen, "Add another" and "View on shelf" are both live,
and nothing anywhere was refused.

-}
manualIsbnDuplicateNoticeInformsWithoutBlocking : Test
manualIsbnDuplicateNoticeInformsWithoutBlocking =
    test "manual_isbn_duplicate: an already-owned book shows the notice and is still added" <|
        \() ->
            startUpload
                |> ProgramTest.update EnterManualMode
                |> ProgramTest.update (ManualIsbnChanged "9780306406157")
                |> ProgramTest.update SubmitManualIsbn
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/books/confirm"
                    (simulateConfirmResponse
                        { statusCode = 200
                        , bookId = "book-1"
                        , title = "The Power of Habit"
                        , authorName = "Charles Duhigg"
                        , source = Just "catalogue"
                        , placements =
                            [ { placementId = "pl-lib", bookshelfName = "library" }
                            , { placementId = "pl-wish", bookshelfName = "wishlist" }
                            ]
                        }
                    )
                -- The add HAPPENED — this is the terminal screen, not a block.
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-complete")
                    , Selector.text "\"The Power of Habit\" added to Wish List"
                    ]
                -- …and the reader is told about the shelf they already had it on.
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-already-yours")
                    , Selector.text "You already have this on your Library."
                    ]
                -- Every control on the completion card still works: "Add
                -- another" returns to the drop zone rather than dead-ending.
                |> ProgramTest.clickButton "Add another"
                |> ProgramTest.expectViewHas
                    [ Selector.text "Drag a photo of a book cover here" ]


{-| The notice must not appear for a book the reader does not own — otherwise
every manual add carries a false "you already have this". The bookshelf this
very request used is not "already", either: it is what just happened, and the
heading already says so.
-}
manualIsbnNoNoticeForABookYouDoNotOwn : Test
manualIsbnNoNoticeForABookYouDoNotOwn =
    test "manual_isbn_no_duplicate: a book placed on one shelf shows no already-yours notice" <|
        \() ->
            startUpload
                |> ProgramTest.update EnterManualMode
                |> ProgramTest.update (ManualIsbnChanged "9780306406157")
                |> ProgramTest.update SubmitManualIsbn
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/books/confirm"
                    (simulateConfirmResponse
                        { statusCode = 201
                        , bookId = "book-1"
                        , title = "The Power of Habit"
                        , authorName = "Charles Duhigg"
                        , source = Nothing
                        , placements = [ { placementId = "pl-wish", bookshelfName = "wishlist" } ]
                        }
                    )
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-complete") ]
                |> ProgramTest.expectViewHasNot
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-already-yours") ]


{-| The photo path's half of the same ruling (#333/#343).

`GET /api/books/:id` has carried every placement since #333, but the upload
flow read only the book out of it, so the verify step — the last moment before
a second copy is filed — said nothing. It now shows the notice, and "Yes,
that's it" is still live: informational, never blocking.

-}
photoPathDuplicateNoticeInformsWithoutBlocking : Test
photoPathDuplicateNoticeInformsWithoutBlocking =
    test "photo_duplicate: a resolved book the reader already owns shows the notice and still advances" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.update (StreamEvent (simulateStreamEvent Resolved (Just "book-1") False))
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-1"
                    (simulateBookDetailResponseWithPlacements "book-1"
                        testBook
                        [ { placementId = "pl-lib", bookshelfName = "library" }
                        , { placementId = "pl-anti", bookshelfName = "antilibrary" }
                        ]
                    )
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-already-yours")
                    , Selector.text "You already have this on your Library and Antilibrary."
                    ]
                -- Nothing is blocked: the verification step still advances…
                |> ProgramTest.clickButton "Yes, that's it"
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-shelf-picker") ]
                -- …and the notice follows the reader to the moment of choosing,
                -- where every shelf — including the ones it is already on —
                -- remains selectable.
                |> ProgramTest.expectViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-already-yours") ]


{-| US-1.1.8 over the wired path (#343).

A second ISBN of a work the platform already holds must offer a MERGE, not
mint a second work. `Books.confirm/2` does the matching (`find_same_work/2`,
Jaro-Winkler > 0.8) and answers 409 with the work id; the client's whole job is
to consume that — it does no matching of its own, which is why the only thing
it needs from the work is a title to put in the sentence.

-}
manualIsbnSameWorkOffersMerge : Test
manualIsbnSameWorkOffersMerge =
    test "manual_isbn_same_work: a second ISBN of an existing work offers the merge prompt, not a second work" <|
        \() ->
            startUpload
                |> ProgramTest.update EnterManualMode
                |> ProgramTest.update (ManualIsbnChanged "9780156453806")
                |> ProgramTest.update SubmitManualIsbn
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/books/confirm"
                    (simulateConfirmMergeRequiredResponse "work-existing-1")
                -- The 409 is an OUTCOME, not an error: no "check the number".
                |> ProgramTest.ensureViewHasNot
                    [ Selector.text "We couldn't find a book with that ISBN. Please check the number and try again." ]
                -- The work is fetched only to name it in the prompt.
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/work-existing-1"
                    (simulateBookResponse "work-existing-1" "The Name of the Rose" "Umberto Eco")
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-same-work")
                    , Selector.text "You already have \"The Name of the Rose\" by Umberto Eco. Add this edition to it?"
                    ]
                -- Merging adds an edition to the named work.
                |> ProgramTest.clickButton "Yes, merge"
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/books/work-existing-1/merge-format"
                    (simulateMergeFormatResponse "work-existing-1" "edition-new-1" "9780156453806" "Paperback")
                |> ProgramTest.expectViewHas
                    [ Selector.text "Added as another edition of the same book." ]


{-| `Books.confirm/2`'s `:already_placed` branch (`source: "collection"`).

Nothing changed server-side, so saying "added to your Wish List" would be the
same untruth as the pre-#333 silent second placement. The completion card must
report what actually happened.

-}
manualIsbnAlreadyOnThatShelfSaysSo : Test
manualIsbnAlreadyOnThatShelfSaysSo =
    test "manual_isbn_already_placed: confirming onto a shelf the book is already on says so rather than claiming an add" <|
        \() ->
            startUpload
                |> ProgramTest.update EnterManualMode
                |> ProgramTest.update (ManualIsbnChanged "9780306406157")
                |> ProgramTest.update SubmitManualIsbn
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/books/confirm"
                    (simulateConfirmResponse
                        { statusCode = 200
                        , bookId = "book-1"
                        , title = "The Power of Habit"
                        , authorName = "Charles Duhigg"
                        , source = Just "collection"
                        , placements = [ { placementId = "pl-wish", bookshelfName = "wishlist" } ]
                        }
                    )
                -- `completeHeading` is one `case` returning one string, so
                -- matching the already-on wording is the same guarantee as
                -- refuting the added-to wording — without a prose negative
                -- that could pass by matching nothing.
                |> ProgramTest.expectViewHas
                    [ Selector.text "\"The Power of Habit\" is already on your Wish List" ]


{-| The reader picks the bookshelf on the manual-entry screen, and that choice
must reach the request — `Books.confirm/2` creates AND places in one
transaction, so a shelf chosen after the fact could only be honoured by filing
the book twice. Clicking "Antilibrary" then the submit button must produce a
confirm whose `shelf_name` is `antilibrary`; the completion card names it back.
-}
manualIsbnHonoursTheChosenShelf : Test
manualIsbnHonoursTheChosenShelf =
    test "manual_isbn_shelf_choice: the bookshelf chosen on the manual screen is the one the book is added to" <|
        \() ->
            startUpload
                |> ProgramTest.clickButton "Enter ISBN manually instead"
                |> ProgramTest.update (ManualIsbnChanged "9780156453806")
                |> ProgramTest.clickButton "Antilibrary"
                |> ProgramTest.clickButton "Add to Antilibrary"
                |> ProgramTest.expectHttpRequest "POST"
                    "/api/books/confirm"
                    (Expect.all
                        [ \body ->
                            Expect.equal (Ok "9780156453806")
                                (Decode.decodeString (Decode.field "isbn" Decode.string) body)
                        , \body ->
                            Expect.equal (Ok "antilibrary")
                                (Decode.decodeString (Decode.field "shelf_name" Decode.string) body)
                        ]
                        << .body
                    )


uploadHappyPath : Test
uploadHappyPath =
    test "upload_happy_path: file selected -> stream resolved -> book identified -> confirmation card shows title and author" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.update (StreamEvent (simulateStreamEvent Resolved (Just "book-1") False))
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-1"
                    (simulateBookResponse "book-1" "Test Book" "Test Author")
                |> ProgramTest.ensureViewHas
                    [ Selector.text "We think this is…" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Test Book" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Test Author" ]


uploadIsbnRejection : Test
uploadIsbnRejection =
    test "upload_isbn_rejection: stream returns Rejected -> shows failure message and retry button" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.update (StreamEvent (simulateStreamEvent Rejected Nothing False))
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Could Not Identify Book" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Try Another Photo" ]


uploadNotABook : Test
uploadNotABook =
    test "upload_not_a_book: stream returns Resolved with no bookId -> shows not-a-book message" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.update (StreamEvent (simulateStreamEvent Resolved Nothing False))
                |> ProgramTest.expectViewHas
                    [ Selector.text "That Doesn't Look Like a Book" ]


uploadPollTimeout : Test
uploadPollTimeout =
    test "upload_poll_timeout: stream error -> shows identification failed" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.update StreamError
                |> ProgramTest.expectViewHas
                    [ Selector.text "Could Not Identify Book" ]


uploadPollTimeoutViaLimit : Test
uploadPollTimeoutViaLimit =
    test "upload_poll_timeout_via_limit: StatusReceived with network error -> IdentificationFailed" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.update (Upload.StatusReceived (Err Http.NetworkError))
                |> ProgramTest.expectViewHas
                    [ Selector.text "Could Not Identify Book" ]


uploadDuplicateDetected : Test
uploadDuplicateDetected =
    test "upload_duplicate_detected: stream returns isDuplicate=True -> shows duplicate card with shelf selector" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.update (StreamEvent (simulateStreamEvent Resolved (Just "book-1") True))
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-1"
                    (simulateBookResponse "book-1" "Duplicate Book" "Dupe Author")
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Already in Your Library" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "upload-duplicate__merge" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Yes, merge" ]


{-| The manual path driven entirely through the affordances a reader can see:
the "Enter ISBN manually instead" link, the ISBN field, and the submit button —
whose label names the bookshelf it will use, because that is what the click
does now.
-}
uploadManualIsbnEntry : Test
uploadManualIsbnEntry =
    test "upload_manual_isbn_entry: click manual mode -> enter valid ISBN -> Add to Wish List -> completion card names the resolved book" <|
        \() ->
            startUpload
                |> ProgramTest.clickButton "Enter ISBN manually instead"
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Enter ISBN Manually" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "isbn-input" ]
                |> ProgramTest.update (ManualIsbnChanged "9780141988511")
                |> ProgramTest.clickButton "Add to Wish List"
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/books/confirm"
                    (simulateConfirmResponse
                        { statusCode = 201
                        , bookId = "book-isbn-1"
                        , title = "Crime and Punishment"
                        , authorName = "Fyodor Dostoevsky"
                        , source = Nothing
                        , placements = [ { placementId = "pl-1", bookshelfName = "wishlist" } ]
                        }
                    )
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-complete") ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Crime and Punishment" ]


uploadMultiBook : Test
uploadMultiBook =
    test "upload_multi_book: stream resolves with 3 bookIds -> fetch all 3 books -> shows Books Identified! and all titles" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.update (StreamEvent (simulateMultiBookStreamEvent [ "book-a", "book-b", "book-c" ]))
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-a"
                    (simulateBookResponse "book-a" "First Book" "Author One")
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-b"
                    (simulateBookResponse "book-b" "Second Book" "Author Two")
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-c"
                    (simulateBookResponse "book-c" "Third Book" "Author Three")
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Books Identified!" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "First Book" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Second Book" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Third Book" ]


uploadMergeFormatSuccess : Test
uploadMergeFormatSuccess =
    test "upload_merge_format_success: duplicate detected -> click Yes merge -> mock 200 response -> shows edition count" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.update (StreamEvent (simulateStreamEvent Resolved (Just "book-1") True))
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-1"
                    (simulateBookWithEditionCount "book-1" "Duplicate Book" "Dupe Author" 1)
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Already in Your Library" ]
                |> ProgramTest.clickButton "Yes, merge"
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/books/book-1/merge-format"
                    (simulateMergeFormatResponse "book-1" "edition-new-1" "9780141988511" "Hardback")
                |> ProgramTest.expectViewHas
                    [ Selector.text "2 editions" ]


uploadMergeFormatFailure : Test
uploadMergeFormatFailure =
    test "upload_merge_format_failure: duplicate detected -> click Yes merge -> mock 500 response -> shows merge failed" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.update (StreamEvent (simulateStreamEvent Resolved (Just "book-1") True))
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-1"
                    (simulateBookResponse "book-1" "Duplicate Book" "Dupe Author")
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Already in Your Library" ]
                |> ProgramTest.clickButton "Yes, merge"
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/books/book-1/merge-format"
                    (Http.BadStatus_
                        { url = "/api/books/book-1/merge-format"
                        , statusCode = 500
                        , statusText = "Internal Server Error"
                        , headers = Dict.empty
                        }
                        ""
                    )
                |> ProgramTest.expectViewHas
                    [ Selector.text "Merge failed" ]


uploadManualIsbnValidation : Test
uploadManualIsbnValidation =
    test "upload_manual_isbn_validation: enter invalid ISBN -> submit -> shows error, state unchanged" <|
        \() ->
            startUpload
                |> ProgramTest.clickButton "Enter ISBN manually instead"
                -- Enter an invalid ISBN
                |> ProgramTest.update (ManualIsbnChanged "1234567890")
                |> ProgramTest.update SubmitManualIsbn
                |> ProgramTest.ensureViewHas
                    [ Selector.class "isbn-input--error" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Invalid ISBN checksum. Please check the number and try again." ]


uploadReset : Test
uploadReset =
    test "upload_reset: from identification failed state -> click reset -> returns to drop zone" <|
        \() ->
            startUpload
                -- Get to IdentificationFailed state via StreamError
                |> simulateUploadAccepted
                |> ProgramTest.update StreamError
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Could Not Identify Book" ]
                -- Click the reset button
                |> ProgramTest.clickButton "Try Another Photo"
                -- Assert we're back at the upload area
                |> ProgramTest.ensureViewHas
                    [ Selector.class "upload-area" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Drag a photo of a book cover here" ]


uploadDragOver : Test
uploadDragOver =
    test "upload_drag_over: DragOver message -> upload-area--dragging class present" <|
        \() ->
            startUpload
                |> ProgramTest.update DragOver
                |> ProgramTest.expectViewHas
                    [ Selector.class "upload-area--dragging" ]


{-| US-1.1.4 sad — age-gate program flow.

Drives the full upload pipeline (init -> upload accepted -> SSE
resolved -> book fetch) for a book whose `visibility_tier` is
`"age_gated"`. The verification view must surface the age-gate notice
with the user-visible message, an `href` to the age-verification
settings page, and a primary CTA that links to it.

-}
uploadAgeGated : Test
uploadAgeGated =
    test "upload_age_gated: resolved age-gated book renders informational age-gate notice (flag on)" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.update (StreamEvent (simulateStreamEvent Resolved (Just "book-age-gated") False))
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-age-gated"
                    (simulateBookWithVisibilityTier "book-age-gated" "Adult Title" "Adult Author" "age_gated")
                -- We are in the verifying step for the identified book.
                |> ProgramTest.ensureViewHas
                    [ Selector.text "We think this is…" ]
                -- Age-gate notice is rendered (informational only — there is no
                -- self-serve "verify age" CTA anymore; ADR-020).
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-age-gate-notice") ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Age verification is required to view its details." ]


{-| US-1.1.7 sad — multi-book partial-failure UX.

Drives a 3-book upload where 2 book fetches succeed and 1 returns a
network error. The Identified state should list the 2 resolved books
alongside a "Could not identify" placeholder, and confirming
placement on a partial-failure result must not crash the program.

-}
uploadMultiBookPartialFailure : Test
uploadMultiBookPartialFailure =
    test "upload_multi_book_partial_failure: 3 bookIds, 2 resolve + 1 rejected -> shows 2 books + 1 placeholder, ConfirmPlacement does not crash" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.update (StreamEvent (simulateMultiBookStreamEvent [ "book-a", "book-b", "book-c" ]))
                -- Two resolve normally...
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-a"
                    (simulateBookResponse "book-a" "First Book" "Author One")
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-b"
                    (simulateBookResponse "book-b" "Second Book" "Author Two")
                -- ...and the third fails the underlying book fetch.
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-c"
                    (Http.BadStatus_
                        { url = "/api/books/book-c"
                        , statusCode = 500
                        , statusText = "Internal Server Error"
                        , headers = Dict.empty
                        }
                        ""
                    )
                -- The two resolved books are listed, alongside a "Could not identify"
                -- placeholder for the failed fetch.
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Books Identified!" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "First Book" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Second Book" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Could not identify" ]
                -- Confirming placement on a partial-failure result must not crash —
                -- the program continues to render the identified list.
                |> ProgramTest.update Upload.ConfirmPlacement
                |> ProgramTest.expectViewHas
                    [ Selector.text "First Book" ]


{-| "No, try again" must keep the image, append the rejected book id to
the cumulative rejection list, dispatch POST .../reject-identification
with that list, and transition the verify step back into the processing
state so the user sees the upload spinner while the new IdentifyBookJob
runs and emits a fresh SSE sequence.
-}
uploadRejectIdentificationRetries : Test
uploadRejectIdentificationRetries =
    test "upload_reject_identification: click 'No, try again' on Verifying step -> POST reject-identification with [bookId] -> view returns to processing spinner" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.update (StreamEvent (simulateStreamEvent Resolved (Just "book-1") False))
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-1"
                    (simulateBookResponse "book-1" "Wrong Guess" "Wrong Author")
                -- Verifying step is now active.
                |> ProgramTest.ensureViewHas
                    [ Selector.text "We think this is…" ]
                -- Click "No, try again" — this fires RejectIdentification.
                |> ProgramTest.clickButton "No, try again"
                -- The server acknowledges the rejection with 202.
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/upload/img-test-001/reject-identification"
                    (Http.GoodStatus_
                        { url = "/api/upload/img-test-001/reject-identification"
                        , statusCode = 202
                        , statusText = "Accepted"
                        , headers = Dict.empty
                        }
                        ""
                    )
                -- Model is back in the Uploading step, processing spinner is showing
                -- while we wait for the re-run vision pipeline to emit SSE events.
                |> ProgramTest.expectViewHas
                    [ Selector.text "Processing image..." ]


{-| #118 — user "adults only" opt-in. On the shelf picker the checkbox is
present; ticking it and confirming placement must fire the raise-only user
age-gate PUT (`/api/books/:id/age-gate` `{adults_only: true}`) alongside the
placement. Simulating the PUT response proves the request was dispatched.
-}
uploadAdultsOnly : Test
uploadAdultsOnly =
    test "upload_adults_only: tick 'adults only' on shelf picker -> ConfirmPlacement fires the raise-only age-gate PUT" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.update (StreamEvent (simulateStreamEvent Resolved (Just "book-1") False))
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-1"
                    (simulateBookResponse "book-1" "Adult Title" "Adult Author")
                -- Move from Verifying to the shelf picker.
                |> ProgramTest.clickButton "Yes, that's it"
                -- The adults-only checkbox is present on the shelf picker.
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-adults-only") ]
                -- Tick it, then confirm placement.
                |> ProgramTest.update ToggleAdultsOnly
                |> ProgramTest.update ConfirmPlacement
                -- The age-gate PUT was dispatched (fails here if it was not).
                |> ProgramTest.simulateHttpResponse "PUT"
                    "/api/books/book-1/age-gate"
                    (Http.GoodStatus_
                        { url = "/api/books/book-1/age-gate"
                        , statusCode = 200
                        , statusText = "OK"
                        , headers = Dict.empty
                        }
                        "{}"
                    )
                -- Placement is still in flight; the spinner is showing.
                |> ProgramTest.expectViewHas
                    [ Selector.text "Adding to shelf..." ]


{-| ADR-020 — age-gating shipped dark. With the server config flag OFF (the
production default) the "adults only" checkbox must NOT render on the shelf
picker, even though every other step of the flow is identical.
-}
uploadAdultsOnlyHiddenWhenFlagOff : Test
uploadAdultsOnlyHiddenWhenFlagOff =
    test "upload_adults_only_hidden_when_flag_off: shelf picker omits the adults-only checkbox when age-gating is disabled" <|
        \() ->
            startUploadAgeGatingOff
                |> simulateUploadAccepted
                |> ProgramTest.update (StreamEvent (simulateStreamEvent Resolved (Just "book-1") False))
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-1"
                    (simulateBookResponse "book-1" "Adult Title" "Adult Author")
                -- Move from Verifying to the shelf picker.
                |> ProgramTest.clickButton "Yes, that's it"
                -- The shelf picker is shown...
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-shelf-picker") ]
                -- ...but the adults-only checkbox is absent (flag off).
                |> ProgramTest.expectViewHasNot
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-adults-only") ]
