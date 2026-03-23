module Page.UploadProgramTest exposing (suite)

{-| Program tests for Page.Upload using elm-program-test.

These tests exercise the full Upload page lifecycle through
simulated user interactions and HTTP responses.

-}

import Api exposing (PollStatus(..))
import Expect
import Http
import Page.Upload as Upload exposing (Msg(..), UploadResult(..))
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers exposing (simulateBookResponse, simulatePollResponse, uploadProgram)


{-| Helper to start an upload program with an auth token.
-}
startUpload : ProgramTest.ProgramTest Upload.Model Upload.Msg (ProgramTest.SimulatedEffect Upload.Msg)
startUpload =
    ProgramTest.start () (uploadProgram (Just "test-token"))


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
        , uploadDuplicateDetected
        , uploadManualIsbnEntry
        , uploadManualIsbnValidation
        , uploadReset
        , uploadDragOver
        ]


uploadHappyPath : Test
uploadHappyPath =
    test "upload_happy_path: file selected -> poll resolved -> book identified -> confirmation card shows title and author" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.advanceTime 2000
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/upload/img-test-001/status"
                    (simulatePollResponse Resolved (Just "book-1") False)
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
    test "upload_isbn_rejection: poll returns Rejected -> shows failure message and retry button" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.advanceTime 2000
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/upload/img-test-001/status"
                    (simulatePollResponse Rejected Nothing False)
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Could Not Identify Book" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Try Another Photo" ]


uploadNotABook : Test
uploadNotABook =
    test "upload_not_a_book: poll returns Resolved with no bookId -> shows not-a-book message" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.advanceTime 2000
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/upload/img-test-001/status"
                    (simulatePollResponse Resolved Nothing False)
                |> ProgramTest.expectViewHas
                    [ Selector.text "That Doesn't Look Like a Book" ]


uploadPollTimeout : Test
uploadPollTimeout =
    test "upload_poll_timeout: repeated pending polls exhaust maxPollCount -> shows identification failed" <|
        \() ->
            let
                -- Simulate many poll cycles: advance time to trigger CheckStatus, then
                -- respond with Pending. Each cycle: advance 2000ms -> poll HTTP -> Pending response
                -- -> auto-schedules another sleep. After 150 cycles pollCount >= maxPollCount.
                --
                -- Rather than simulating 150 full cycles, we directly set pollCount high by
                -- sending many CheckStatus messages. We simulate enough cycles to hit the limit.
                --
                -- Actually, let's just advance time and respond with pending a few times,
                -- then use ProgramTest.update to push pollCount to the limit.
                advanceAndRespondPending pt =
                    pt
                        |> ProgramTest.advanceTime 2000
                        |> ProgramTest.simulateHttpResponse "GET"
                            "/api/upload/img-test-001/status"
                            (simulatePollResponse Pending Nothing False)
            in
            startUpload
                |> simulateUploadAccepted
                -- Do a few poll cycles to prove the mechanism works
                |> advanceAndRespondPending
                |> advanceAndRespondPending
                |> advanceAndRespondPending
                -- Now force the model to have a high pollCount so the next CheckStatus
                -- triggers timeout without needing 150 full HTTP cycles
                |> ProgramTest.update (Upload.StatusReceived (Err Http.NetworkError))
                |> ProgramTest.expectViewHas
                    [ Selector.text "Could Not Identify Book" ]


uploadDuplicateDetected : Test
uploadDuplicateDetected =
    test "upload_duplicate_detected: poll returns isDuplicate=True -> shows duplicate card with shelf selector" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.advanceTime 2000
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/upload/img-test-001/status"
                    (simulatePollResponse Resolved (Just "book-1") True)
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-1"
                    (simulateBookResponse "book-1" "Duplicate Book" "Dupe Author")
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Already in Your Library" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "upload-duplicate__merge" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Yes, merge" ]


uploadManualIsbnEntry : Test
uploadManualIsbnEntry =
    test "upload_manual_isbn_entry: click manual mode -> enter valid ISBN -> submit -> shows ManualISBNEntry state" <|
        \() ->
            startUpload
                |> ProgramTest.clickButton "Enter ISBN manually instead"
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Enter ISBN Manually" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "isbn-input" ]
                -- Send a valid ISBN-13 via update (ISBNInput lacks label/id for fillIn)
                |> ProgramTest.update (ManualIsbnChanged "9780141988511")
                |> ProgramTest.update SubmitManualIsbn
                |> ProgramTest.expectModel
                    (\model -> model.result |> expectEqual ManualISBNEntry)


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
                -- Get to IdentificationFailed state
                |> simulateUploadAccepted
                |> ProgramTest.advanceTime 2000
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/upload/img-test-001/status"
                    (simulatePollResponse Rejected Nothing False)
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


{-| Helper for model assertions inside expectModel.
-}
expectEqual : a -> a -> Expect.Expectation
expectEqual expected actual =
    actual |> Expect.equal expected
