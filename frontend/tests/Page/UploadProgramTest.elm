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
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers
    exposing
        ( simulateBookDetailResponseWithPlacements
        , simulateBookResponse
        , simulateConfirmMergeRequiredResponse
        , simulateConfirmResponse
        , simulateMergeFormatResponse
        , testBook
        , testPlacement
        , uploadProgram
        , uploadProgramWithInbox
        )
import Types.RemoteData


{-| Helper to start an upload program with an auth token and age-gating ON. Most flows are age-gating-agnostic; the flag-off behaviour is
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


{-| Build an SSE frame exactly as the server emits it — the one wire shape
is `ProtoJSON.poll_response/1` (snake\_case, all six keys always present,
nulls not omissions). Fixtures built by hand instead of through this
drifted from the wire for months.
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

                TimedOut ->
                    "timeout"

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


{-| A rejection frame carrying the reason the server actually attached.

`simulateStreamEvent` hardcodes `rejection_reason: null`, which is a frame the
server emits only on the resolved/timeout branches — so every rejection test
written through it was exercising the "no reason given" path while claiming to
cover the reasoned ones. The tokens accepted here are exactly those
`Stacks.AI.VisionError.reason_token/1` and `Stacks.Workers.IdentifyBookJob` can
write.

-}
simulateRejection : String -> String
simulateRejection reason =
    Encode.encode 0
        (Encode.object
            [ ( "image_id", Encode.string "img-test-001" )
            , ( "status", Encode.string "rejected" )
            , ( "book_id", Encode.null )
            , ( "book_ids", Encode.list Encode.string [] )
            , ( "rejection_reason", Encode.string reason )
            , ( "is_duplicate", Encode.bool False )
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
        , uploadFailureCauses
        , uploadUnknownCauseAdmitsIt
        , uploadSendFailures
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
        , inboxListsWhatIsWaiting
        , inboxRendersNothingWhenEmpty
        , inboxNamesTheFailureCause
        , inboxResumesTheExistingConfirmFlow
        , inboxPlacesNothingByItself
        , inboxResumeToAShelfIsFourDeliberateSteps
        , inboxResumeKeepsNoTryAgain
        , waitingCopyOffersTheDoorAfterTwentySeconds
        , waitingCopySaysNothingAboutRetries
        , waitingWatchdogNoticesASilentStream
        , waitingWatchdogIsResetByAHeartbeat
        , shelvingABookAsksForTheInboxAgain
        , uploadProgressIsAnAriaLiveRegion
        ]


{-| The upload flow's status — "Reading your photo…", "Book Identified!", every
failure card — is swapped in and out of one region as identification proceeds. A
screen-reader user watching that region must be told when it changes, so it
carries `aria-live="polite"` (TR-6,). The `polite` value (not
`assertive`) is asserted exactly, because an assertive region would interrupt the
reader on every progress tick.
-}
uploadProgressIsAnAriaLiveRegion : Test
uploadProgressIsAnAriaLiveRegion =
    test "upload_progress_is_an_aria_live_region: the status region announces politely" <|
        \() ->
            startUpload
                |> ProgramTest.expectViewHas
                    [ Selector.class "upload-status-region"
                    , Selector.attribute (Html.Attributes.attribute "aria-live" "polite")
                    ]


{-| Placing or adding a book must tell the shell the inbox has changed.

⛔ Found by a probe that reddened nothing: replacing `RefreshInbox` with
`NoOut` left every test green because `uploadProgram`'s update wrapper
discards `Upload.update`'s third tuple element. This test observes the
OutMsg itself, so the badge cannot silently keep showing a shelved book.

-}
shelvingABookAsksForTheInboxAgain : Test
shelvingABookAsksForTheInboxAgain =
    describe "shelving_a_book_asks_for_the_inbox_again"
        [ test "a completed placement raises RefreshInbox" <|
            \() ->
                outMsgOf
                    (PlacementCompleted (Ok testPlacement))
                    { emptyUpload | step = Upload.ChoosingShelf testBook }
                    |> Expect.equal Upload.RefreshInbox
        , test "a failed placement does not — nothing left the inbox" <|
            \() ->
                outMsgOf
                    (PlacementCompleted (Err Api.PlaceReadingPileFull))
                    { emptyUpload | step = Upload.ChoosingShelf testBook }
                    |> Expect.equal Upload.NoOut
        , test "choosing a shelf does not — the book is not filed yet" <|
            \() ->
                outMsgOf (ShelfSelected "library")
                    { emptyUpload | step = Upload.ChoosingShelf testBook }
                    |> Expect.equal Upload.NoOut
        ]


emptyUpload : Upload.Model
emptyUpload =
    Upload.init


outMsgOf : Upload.Msg -> Upload.Model -> Upload.OutMsg
outMsgOf msg model =
    let
        ( _, _, out ) =
            Upload.update msg model (Just "test-token")
    in
    out


{-| An inbox item as `GET /api/uploads/inbox` delivers it.
-}
awaitingItem : String -> String -> Api.InboxItem
awaitingItem imageId bookId =
    { imageId = imageId
    , kind = Api.AwaitingConfirmation
    , bookIds = [ bookId ]
    , rejectionReason = Nothing
    }


failedItem : String -> Maybe String -> Api.InboxItem
failedItem imageId reason =
    { imageId = imageId
    , kind = Api.Failed
    , bookIds = []
    , rejectionReason = reason
    }


startWithInbox :
    List Api.InboxItem
    -> ProgramTest.ProgramTest Upload.Model Upload.Msg (ProgramTest.SimulatedEffect Upload.Msg)
startWithInbox items =
    ProgramTest.start ()
        (uploadProgramWithInbox True (Just "test-token") (Types.RemoteData.Success items))


testIdSelector : String -> Selector.Selector
testIdSelector value =
    Selector.attribute (Html.Attributes.attribute "data-testid" value)


{-| A 201 from `POST /api/bookshelves/:name/placements`, in the shape
`Api.placeResponseToResult` actually parses — the placement nested under a
`placement` key. A bare `{}` decodes to a `BadBody` and renders the "Failed to
add book" branch, which would have made the four-step test pass its "no
placement happened" sibling for the wrong reason.
-}
simulatePlacementCreated : String -> String -> Http.Response String
simulatePlacementCreated shelfName bookId =
    let
        url =
            "/api/bookshelves/" ++ shelfName ++ "/placements"
    in
    Http.GoodStatus_
        { url = url
        , statusCode = 201
        , statusText = "Created"
        , headers = Dict.empty
        }
        (Encode.encode 0
            (Encode.object
                [ ( "placement"
                  , Encode.object
                        [ ( "id", Encode.string "placement-1" )
                        , ( "book_id", Encode.string bookId )
                        , ( "bookshelf_name", Encode.string shelfName )
                        , ( "formats", Encode.list Encode.string [] )
                        , ( "visibility", Encode.null )
                        , ( "bookshelf_visibility", Encode.null )
                        ]
                  )
                ]
            )
        )


{-| — the inbox exists and says what is in it.
-}
inboxListsWhatIsWaiting : Test
inboxListsWhatIsWaiting =
    test "inbox_lists_what_is_waiting: unfinished uploads are reachable from the upload page" <|
        \() ->
            startWithInbox [ awaitingItem "img-1" "book-1", failedItem "img-2" (Just "isbn_not_found") ]
                |> ProgramTest.ensureViewHas [ testIdSelector "upload-inbox" ]
                |> ProgramTest.expectView
                    (Query.findAll [ testIdSelector "upload-inbox-item" ]
                        >> Query.count (Expect.equal 2)
                    )


{-| An empty inbox is not an empty box with a heading on it — it is nothing.

The anti-vacuity companion is `inboxListsWhatIsWaiting` above: without it,
"renders nothing" would pass just as happily against an inbox that never
rendered at all.

-}
inboxRendersNothingWhenEmpty : Test
inboxRendersNothingWhenEmpty =
    test "inbox_renders_nothing_when_empty: no heading, no list, no empty state" <|
        \() ->
            startWithInbox []
                |> ProgramTest.expectViewHasNot [ testIdSelector "upload-inbox" ]


{-| causes must survive the trip through the inbox.

A rejection the reader never witnessed is the ONLY way they will ever learn
what happened to that photo, so the sentence has to be the specific one — not
the generic "we couldn't identify this one" the issue's own summary line used
as shorthand. Both items below are failures; they must not say the same thing.

-}
inboxNamesTheFailureCause : Test
inboxNamesTheFailureCause =
    test "inbox_names_the_failure_cause: each failure keeps the cause gave it" <|
        \() ->
            startWithInbox
                [ failedItem "img-1" (Just "vision_unavailable")
                , failedItem "img-2" (Just "isbn_not_found")
                , failedItem "img-3" (Just "not_a_book")
                , failedItem "img-4" Nothing
                ]
                |> ProgramTest.expectView
                    (Expect.all
                        [ Query.has [ Selector.text "The service that reads book covers is not answering. There is nothing wrong with your photo. Type the ISBN in to add the book now, or try the photo again later." ]
                        , Query.has [ Selector.text "We found a book but could not make out its ISBN. A closer photo of the barcode or the copyright page will usually do it — or type the number in." ]
                        , Query.has [ Selector.text "We couldn't detect a book in that image. Please try a photo of a book cover." ]
                        , Query.has [ Selector.text "Your photo did not become a book, and we cannot say why. It may be nothing to do with the photo. Try again in a moment, or type the ISBN in." ]
                        ]
                    )


{-| The acceptance test for "resumes the EXISTING flow" (DoD item 3).

Selecting an inbox item must land on the same "We think this is…" verify step a
live stream produces, having issued the same `GET /api/books/:id` — not a new
screen, not a shortcut. The request assertion is what makes this more than a
rendering check: `simulateHttpResponse` fails outright if the program never
made the request, so a resume that skipped the fetch cannot pass.

-}
inboxResumesTheExistingConfirmFlow : Test
inboxResumesTheExistingConfirmFlow =
    test "inbox_resumes_the_existing_confirm_flow: selecting an item enters the verify step" <|
        \() ->
            startWithInbox [ awaitingItem "img-1" "book-1" ]
                |> ProgramTest.clickButton "Check this one"
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-1"
                    (simulateBookResponse "book-1" "Piranesi" "Susanna Clarke")
                |> ProgramTest.expectView
                    (Expect.all
                        [ Query.has [ testIdSelector "upload-verify" ]
                        , Query.has [ Selector.text "We think this is…" ]
                        , Query.has [ Selector.text "Piranesi" ]
                        , Query.has [ Selector.text "Yes, that's it" ]
                        , Query.has [ Selector.text "No, try again" ]
                        ]
                    )


{-| ⛔ THE INVARIANT: incorrect classifications must never end up on
shelves they were not intended for. Identification is asynchronous;
placement must not be. Asserts the ABSENCE directly — resume an inbox
item, let its book load, and prove no placement request was dispatched
and the confirm affordance is still the only path to a shelf.
-}
inboxPlacesNothingByItself : Test
inboxPlacesNothingByItself =
    test "inbox_places_nothing_by_itself: resuming an item files no book on any shelf" <|
        \() ->
            startWithInbox [ awaitingItem "img-1" "book-1" ]
                |> ProgramTest.clickButton "Check this one"
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-1"
                    (simulateBookResponse "book-1" "Piranesi" "Susanna Clarke")
                |> ProgramTest.ensureHttpRequests "POST"
                    "/api/bookshelves/library/placements"
                    (Expect.equal [])
                |> ProgramTest.ensureHttpRequests "POST"
                    "/api/bookshelves/wishlist/placements"
                    (Expect.equal [])
                |> ProgramTest.expectViewHasNot [ testIdSelector "upload-complete" ]


{-| The whole journey, counted: an inbox item reaches a bookshelf only by way of
a human answering two questions and pressing a third button.

This is the positive half of `inboxPlacesNothingByItself`, and it exists so
that "no placement happened" cannot be satisfied by a resume that does nothing
at all. Each step is named; remove any one of them and the placement never
happens.

-}
inboxResumeToAShelfIsFourDeliberateSteps : Test
inboxResumeToAShelfIsFourDeliberateSteps =
    test "inbox_resume_to_a_shelf_is_four_deliberate_steps: pick, confirm, choose, place" <|
        \() ->
            startWithInbox [ awaitingItem "img-1" "book-1" ]
                |> ProgramTest.clickButton "Check this one"
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-1"
                    (simulateBookResponse "book-1" "Piranesi" "Susanna Clarke")
                |> ProgramTest.clickButton "Yes, that's it"
                |> ProgramTest.ensureViewHas [ testIdSelector "upload-shelf-picker" ]
                |> ProgramTest.clickButton "Library"
                |> ProgramTest.clickButton "Add to Library"
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/bookshelves/library/placements"
                    (simulatePlacementCreated "library" "book-1")
                |> ProgramTest.expectViewHas [ testIdSelector "upload-complete" ]


{-| "No, try again" must still work on a resumed item.

It is the affordance that needs the image id, and the image id is the reason
resuming sets `uploadState` to `Success item.imageId` rather than simply
rendering a book. A resume that only set the step would leave the reader looking
at a wrong guess with the correction button wired to a full reset — dropping
them back at the drop zone with the cumulative exclusion list thrown away.

-}
inboxResumeKeepsNoTryAgain : Test
inboxResumeKeepsNoTryAgain =
    test "inbox_resume_keeps_no_try_again: rejecting a resumed guess re-runs identification for that image" <|
        \() ->
            startWithInbox [ awaitingItem "img-from-inbox" "book-1" ]
                |> ProgramTest.clickButton "Check this one"
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-1"
                    (simulateBookResponse "book-1" "Wrong Book" "Wrong Author")
                |> ProgramTest.clickButton "No, try again"
                |> ProgramTest.expectHttpRequest "POST"
                    "/api/upload/img-from-inbox/reject-identification"
                    (.body >> Expect.equal "{\"rejected_book_ids\":[\"book-1\"]}")


{-| requirement 5 — offer the exit honestly, on elapsed time.

Before the threshold the page says nothing about leaving; after it, it does.
Asserting both directions is what stops this passing against copy that was
always on screen (which would be a page telling every reader their upload is
slow, five seconds in).

-}
waitingCopyOffersTheDoorAfterTwentySeconds : Test
waitingCopyOffersTheDoorAfterTwentySeconds =
    test "waiting_copy_offers_the_door_after_twenty_seconds: elapsed time, not imminence" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.ensureViewHasNot [ testIdSelector "upload-leave-note" ]
                |> ProgramTest.update WaitTick
                |> ProgramTest.update WaitTick
                |> ProgramTest.update WaitTick
                |> ProgramTest.ensureViewHasNot [ testIdSelector "upload-leave-note" ]
                |> ProgramTest.update WaitTick
                |> ProgramTest.expectViewHas
                    [ testIdSelector "upload-leave-note"
                    , Selector.text "This one is taking a while. You don't have to wait — you can close this page and carry on. We'll keep going, and the result will be waiting for you under Add a Book."
                    ]


{-| ⛔ No invented retry copy: the row stays `pending` across the job's
retries, no frame is broadcast between them, and the client cannot know
which attempt is running — so the waiting screen must not claim
"retrying" or "attempt 2 of 3". Pins the copy to what the wire proves.
-}
waitingCopySaysNothingAboutRetries : Test
waitingCopySaysNothingAboutRetries =
    test "waiting_copy_says_nothing_about_retries: the waiting screen says exactly two things, ever" <|
        \() ->
            List.range 1 24
                |> List.foldl (\_ program -> ProgramTest.update WaitTick program)
                    (simulateUploadAccepted startUpload)
                |> ProgramTest.expectView
                    (Query.find [ testIdSelector "upload-loading" ]
                        >> Expect.all
                            [ Query.findAll [ Selector.tag "p" ]
                                >> Query.count (Expect.equal 2)
                            , Query.has [ Selector.text "Reading your photo..." ]
                            , Query.has [ Selector.text "This page has stopped hearing back from the library. Identification is still running — the result will be waiting for you under Add a Book whenever you return." ]
                            ]
                    )


{-| The watchdog left for this issue.

An `EventSource` that opens and then emits neither a message nor an error used
to leave the spinner turning until the server's own deadline — as long as 23
minutes — because the client had no way to tell a slow pipeline from a dead
socket. It still cannot tell what the JOB is doing, and does not claim to: the
copy is about the connection, and points at the inbox.

-}
waitingWatchdogNoticesASilentStream : Test
waitingWatchdogNoticesASilentStream =
    test "waiting_watchdog_notices_a_silent_stream: nine ticks of silence is reported as silence" <|
        \() ->
            List.range 1 9
                |> List.foldl (\_ program -> ProgramTest.update WaitTick program)
                    (simulateUploadAccepted startUpload)
                |> ProgramTest.expectView
                    (Expect.all
                        [ Query.has
                            [ testIdSelector "upload-stream-silent"
                            , Selector.text "This page has stopped hearing back from the library. Identification is still running — the result will be waiting for you under Add a Book whenever you return."
                            ]
                        , Query.hasNot [ testIdSelector "upload-error" ]
                        ]
                    )


{-| The reset is on EVERY frame, including the heartbeats that fail to decode.

`streamEventDecoder` rejects `{"type":"heartbeat"}` on purpose, and
`Page.Upload` drops it as a status — but its arrival is proof the stream is
alive, and that proof is the entire content of the watchdog. Resetting inside
the decoder's `Ok` branch instead would declare a perfectly healthy connection
dead after 45 seconds of a slow-but-working pipeline.

-}
waitingWatchdogIsResetByAHeartbeat : Test
waitingWatchdogIsResetByAHeartbeat =
    test "waiting_watchdog_is_reset_by_a_heartbeat: an undecodable keepalive still counts as contact" <|
        \() ->
            List.range 1 8
                |> List.foldl (\_ program -> ProgramTest.update WaitTick program)
                    (simulateUploadAccepted startUpload)
                |> ProgramTest.update (StreamEvent "{\"type\":\"heartbeat\"}")
                |> ProgramTest.update WaitTick
                |> ProgramTest.update WaitTick
                |> ProgramTest.expectView
                    (Expect.all
                        [ Query.hasNot [ testIdSelector "upload-stream-silent" ]
                        , Query.has [ testIdSelector "upload-leave-note" ]
                        ]
                    )


{-| The manual-entry acceptance test: a checksum-valid ISBN the catalogue
has never seen must succeed. The old DIY flow GETed
`/api/books/isbn/:isbn` (which only consults `find_existing/1`), so an
unseen valid ISBN 404'd and the reader was told to "check the ISBN" —
for a number that was correct. `confirmBook` resolves and places in one
call.
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


{-| , re-driven over the wired path.

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
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-complete")
                    , Selector.text "\"The Power of Habit\" added to Wish List"
                    ]
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-already-yours")
                    , Selector.text "You already have this on your Library."
                    ]
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


{-| The photo path's half of the same ruling.

`GET /api/books/:id` has carried every placement since, but the upload
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
                |> ProgramTest.clickButton "Yes, that's it"
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-shelf-picker") ]
                |> ProgramTest.expectViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-already-yours") ]


{-| over the wired path.

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
                |> ProgramTest.ensureViewHasNot
                    [ Selector.text "We couldn't find a book with that ISBN. Please check the number and try again." ]
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/work-existing-1"
                    (simulateBookResponse "work-existing-1" "The Name of the Rose" "Umberto Eco")
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-same-work")
                    , Selector.text "You already have \"The Name of the Rose\" by Umberto Eco. Add this edition to it?"
                    ]
                |> ProgramTest.clickButton "Yes, merge"
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/books/work-existing-1/merge-format"
                    (simulateMergeFormatResponse "work-existing-1" "edition-new-1" "9780156453806" "Paperback")
                |> ProgramTest.ensureViewHasNot
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-same-work") ]
                |> ProgramTest.ensureViewHasNot
                    [ Selector.text "You already have \"The Name of the Rose\" by Umberto Eco. Add this edition to it?" ]
                |> ProgramTest.ensureViewHasNot [ Selector.text "Yes, merge" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-merge-complete")
                    , Selector.text "\"The Name of the Rose\" has a new edition"
                    , Selector.text "The Paperback edition (ISBN 9780156453806) is now listed on the book's page."
                    ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "It isn't on one of your bookshelves yet — open the book to add it." ]


{-| `Books.confirm/2`'s `:already_placed` branch (`source: "collection"`).

Nothing changed server-side, so saying "added to your Wish List" would be the
same untruth as the pre-silent second placement. The completion card must
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
    test "upload_isbn_rejection: stream returns isbn_not_found -> shows failure message and retry button" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.update (StreamEvent (simulateRejection "isbn_not_found"))
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Could Not Read the ISBN" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Try Another Photo" ]


{-| Four causes, four messages — the whole of first requirement.

Each leg drives the REAL path end to end: a server-shaped SSE frame through
`Api.streamEventDecoder`, through `Page.Upload.update`, into the rendered view.
Nothing is stubbed between the wire and the words.

⛔ Each leg also asserts that the message does **not** contain the sentence the
other causes would have produced. Without that half, this file would pass on a
`viewIdentificationFailed` that ignored its argument entirely — which is exactly
the state the page was in before this issue, and exactly what the four green
tests it already had failed to notice.

-}
uploadFailureCauses : Test
uploadFailureCauses =
    describe "each terminal cause says what happened"
        [ test "undecodable_image blames the file, not the photograph's clarity" <|
            \() ->
                startUpload
                    |> simulateUploadAccepted
                    |> ProgramTest.update (StreamEvent (simulateRejection "undecodable_image"))
                    |> ProgramTest.ensureViewHas
                        [ Selector.text "That Photo Could Not Be Opened" ]
                    |> onlyFailureCause "image-unreadable"
        , test "image_too_large is an unreadable file, not an unreadable ISBN" <|
            \() ->
                startUpload
                    |> simulateUploadAccepted
                    |> ProgramTest.update (StreamEvent (simulateRejection "image_too_large"))
                    |> ProgramTest.ensureViewHas
                        [ Selector.text "That Photo Could Not Be Opened" ]
                    |> onlyFailureCause "image-unreadable"
        , test "isbn_not_found keeps the message that was always about it" <|
            \() ->
                startUpload
                    |> simulateUploadAccepted
                    |> ProgramTest.update (StreamEvent (simulateRejection "isbn_not_found"))
                    |> ProgramTest.ensureViewHas
                        [ Selector.text "We found a book but could not make out its ISBN." ]
                    |> onlyFailureCause "isbn-unreadable"
        , test "not_a_book keeps its own card" <|
            \() ->
                startUpload
                    |> simulateUploadAccepted
                    |> ProgramTest.update (StreamEvent (simulateRejection "not_a_book"))
                    |> ProgramTest.expectViewHas
                        [ Selector.text "That Doesn't Look Like a Book" ]
        , test "vision_unavailable tells the reader their photo is fine" <|
            \() ->
                startUpload
                    |> simulateUploadAccepted
                    |> ProgramTest.update (StreamEvent (simulateRejection "vision_unavailable"))
                    |> ProgramTest.ensureViewHas
                        [ Selector.text "The Cataloguing Desk Is Closed" ]
                    |> ProgramTest.ensureViewHas
                        [ Selector.text "There is nothing wrong with your photo." ]
                    |> onlyFailureCause "service-unavailable"
        , test "vision_budget_exceeded is the same outage from the reader's side" <|
            \() ->
                startUpload
                    |> simulateUploadAccepted
                    |> ProgramTest.update (StreamEvent (simulateRejection "vision_budget_exceeded"))
                    |> ProgramTest.ensureViewHas
                        [ Selector.text "The Cataloguing Desk Is Closed" ]
                    |> onlyFailureCause "service-unavailable"
        , test "the SSE timeout frame reports no verdict, not a bad photo" <|
            \() ->
                startUpload
                    |> simulateUploadAccepted
                    |> ProgramTest.update (StreamEvent (simulateStreamEvent TimedOut Nothing False))
                    |> ProgramTest.ensureViewHas
                        [ Selector.text "No Answer Came Back" ]
                    |> ProgramTest.ensureViewHas
                        [ Selector.text "Nothing has been added to your shelves." ]
                    |> onlyFailureCause "timed-out"
        ]


{-| The cause on screen is the one named, and none of the others.

⛔ Anchored on the `data-failure-cause` attribute rather than on absent prose,
which is what `scripts/check-prose-assertions.sh` exists to insist on:
`Selector.text` matches a SUBSTRING, so "could not make out its ISBN" would be
satisfied — or not — by accidents of wording rather than by which card rendered.
An attribute value is exact.

It asserts against the WHOLE roster, not just against one wrong answer, so a
`viewIdentificationFailed` that ignored its argument fails here for every cause
but the one it happens to be stuck on. (Measured: pinning the view to
`IsbnUnreadable` reddens eleven tests.)

-}
onlyFailureCause :
    String
    -> ProgramTest.ProgramTest Upload.Model Upload.Msg (ProgramTest.SimulatedEffect Upload.Msg)
    -> Expect.Expectation
onlyFailureCause expected program =
    let
        allCauses =
            [ "image-unreadable"
            , "isbn-unreadable"
            , "service-unavailable"
            , "timed-out"
            , "connection-lost"
            , "unknown"
            , "not-a-book"
            , "not-sent"
            ]

        card cause =
            Selector.attribute (Html.Attributes.attribute "data-failure-cause" cause)
    in
    allCauses
        |> List.filter (\cause -> cause /= expected)
        |> List.foldl (\cause acc -> ProgramTest.ensureViewHasNot [ card cause ] acc)
            (ProgramTest.ensureViewHas [ card expected ] program)
        |> ProgramTest.done


{-| ⛔ The requirement this whole issue exists for (requirement 2, requirement 5).

An unrecognised rejection token is what a server that grew a new one after this
client shipped looks like. The page must answer that with an admission, not with
one of the five explanations it happens to know — and `processing_failed` is the
same case wearing the server's own "I don't know" label.

-}
uploadUnknownCauseAdmitsIt : Test
uploadUnknownCauseAdmitsIt =
    describe "an unknown cause is reported as unknown"
        [ test "a token this client has never seen claims nothing" <|
            \() ->
                startUpload
                    |> simulateUploadAccepted
                    |> ProgramTest.update (StreamEvent (simulateRejection "shelf_gremlins"))
                    |> ProgramTest.ensureViewHas
                        [ Selector.text "we cannot say why" ]
                    |> onlyFailureCause "unknown"
        , test "processing_failed, the server's own shrug, is passed on as one" <|
            \() ->
                startUpload
                    |> simulateUploadAccepted
                    |> ProgramTest.update (StreamEvent (simulateRejection "processing_failed"))
                    |> ProgramTest.ensureViewHas
                        [ Selector.text "It may be nothing to do with the photo." ]
                    |> onlyFailureCause "unknown"
        , test "a rejection with no reason attached claims nothing either" <|
            \() ->
                startUpload
                    |> simulateUploadAccepted
                    |> ProgramTest.update (StreamEvent (simulateStreamEvent Rejected Nothing False))
                    |> ProgramTest.ensureViewHas
                        [ Selector.text "we cannot say why" ]
                    |> onlyFailureCause "unknown"
        ]


{-| The pre-identification failures: the photo never reached the library.

`uploadState` used to be overwritten with a literal `Http.NetworkError` at both
of these call sites, so a 429 and a 413 both rendered as "Upload failed. Please
try again." — advice that cannot work for either.

-}
uploadSendFailures : Test
uploadSendFailures =
    describe "a photo that never got sent says why"
        [ test "a 429 on the presign says wait, not retry" <|
            \() ->
                startUpload
                    |> ProgramTest.update (UploadAccepted (Err (Http.BadStatus 429)))
                    |> ProgramTest.expectViewHas
                        [ Selector.attribute (Html.Attributes.attribute "data-failure-cause" "not-sent")
                        , Selector.text "Too many attempts from here just now. Please wait a little while before trying again."
                        ]
        , test "a 413 says the file is too large" <|
            \() ->
                startUpload
                    |> ProgramTest.update (UploadAccepted (Err (Http.BadStatus 413)))
                    |> ProgramTest.expectViewHas
                        [ Selector.text "That photo is too large to send. A smaller one — or your phone's own resized copy — will go through." ]
        , test "an unrecognised status admits it is unrecognised" <|
            \() ->
                startUpload
                    |> ProgramTest.update (UploadAccepted (Err (Http.BadStatus 418)))
                    |> ProgramTest.expectViewHas
                        [ Selector.text "Your photo could not be sent, and we cannot say why. Please try again in a moment." ]
        , test "⛔ the three do not share a sentence" <|
            \() ->
                [ Http.BadStatus 429, Http.BadStatus 413, Http.BadStatus 418 ]
                    |> List.map (\err -> Upload.sendError err)
                    |> distinctCount
                    |> Expect.equal 3
        , -- ⛔ Added because a probe found nothing (#374).
          test "a 429 on the R2 PUT keeps its status instead of becoming a network error" <|
            \() ->
                startUpload
                    |> ProgramTest.update (Upload.R2PutCompleted "img-test-001" "test-token" (Err (Http.BadStatus 429)))
                    |> ProgramTest.expectViewHas
                        [ Selector.text "Too many attempts from here just now. Please wait a little while before trying again." ]
        ]


distinctCount : List String -> Int
distinctCount =
    List.foldl
        (\item seen ->
            if List.member item seen then
                seen

            else
                item :: seen
        )
        []
        >> List.length


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
    test "upload_poll_timeout: stream error -> reports the lost connection" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.update StreamError
                |> ProgramTest.expectViewHas
                    [ Selector.text "The Library Is Unreachable" ]


uploadPollTimeoutViaLimit : Test
uploadPollTimeoutViaLimit =
    test "upload_poll_timeout_via_limit: StatusReceived with network error -> IdentificationFailed" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.update (Upload.StatusReceived (Err Http.NetworkError))
                |> ProgramTest.expectViewHas
                    [ Selector.text "The Library Is Unreachable" ]


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
    test "upload_merge_format_success: duplicate detected -> click Yes merge -> mock 200 response -> completion card names the merged edition" <|
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
                |> ProgramTest.ensureViewHasNot [ Selector.text "Already in Your Library" ]
                |> ProgramTest.ensureViewHasNot [ Selector.text "Yes, merge" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-merge-complete")
                    , Selector.text "\"Duplicate Book\" has a new edition"
                    , Selector.text "The Hardback edition (ISBN 9780141988511) is now listed on the book's page."
                    ]
                |> ProgramTest.expectViewHasNot
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-merge-shelf-hint") ]


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
                |> simulateUploadAccepted
                |> ProgramTest.update StreamError
                |> ProgramTest.ensureViewHas
                    [ Selector.text "The Library Is Unreachable" ]
                |> ProgramTest.clickButton "Try Another Photo"
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


{-| sad — age-gate program flow.

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
                |> ProgramTest.ensureViewHas
                    [ Selector.text "We think this is…" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-age-gate-notice") ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Age verification is required to view its details." ]


{-| sad — multi-book partial-failure UX.

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
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-a"
                    (simulateBookResponse "book-a" "First Book" "Author One")
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-b"
                    (simulateBookResponse "book-b" "Second Book" "Author Two")
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
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Books Identified!" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "First Book" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Second Book" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Could not identify" ]
                |> ProgramTest.update Upload.ConfirmPlacement
                |> ProgramTest.expectViewHas
                    [ Selector.text "First Book" ]


{-| "No, try again" must keep the image, append the rejected book id to
the cumulative rejection list, dispatch POST.../reject-identification
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
                |> ProgramTest.ensureViewHas
                    [ Selector.text "We think this is…" ]
                |> ProgramTest.clickButton "No, try again"
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
                |> ProgramTest.expectViewHas
                    [ testIdSelector "upload-loading"
                    , Selector.text "Reading your photo..."
                    ]


{-| — user "adults only" opt-in. On the shelf picker the checkbox is
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
                |> ProgramTest.clickButton "Yes, that's it"
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-adults-only") ]
                |> ProgramTest.update ToggleAdultsOnly
                |> ProgramTest.update ConfirmPlacement
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
                |> ProgramTest.expectViewHas
                    [ Selector.text "Adding to shelf..." ]


{-| age-gating shipped dark. With the server config flag OFF (the
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
                |> ProgramTest.clickButton "Yes, that's it"
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-shelf-picker") ]
                |> ProgramTest.expectViewHasNot
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-adults-only") ]
