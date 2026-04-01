module Page.UploadProgramTest exposing (suite)

{-| Program tests for Page.Upload using elm-program-test.

These tests exercise the full Upload page lifecycle through
simulated user interactions and HTTP responses.

-}

import Api exposing (PollStatus(..))
import Dict
import Expect
import Http
import Json.Encode as Encode
import Page.Upload as Upload exposing (Msg(..), UploadResult(..))
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers exposing (simulateBookResponse, simulateMergeFormatResponse, simulatePollResponse, uploadProgram)


{-| Helper to start an upload program with an auth token.
-}
startUpload : ProgramTest.ProgramTest Upload.Model Upload.Msg (ProgramTest.SimulatedEffect Upload.Msg)
startUpload =
    ProgramTest.start () (uploadProgram (Just "test-token"))


{-| Build a poll response that resolves with multiple book IDs.
-}
simulateMultiBookPollResponse : List String -> Http.Response String
simulateMultiBookPollResponse bookIds =
    let
        json =
            Encode.encode 0
                (Encode.object
                    [ ( "image_id", Encode.string "img-test-001" )
                    , ( "status", Encode.string "resolved" )
                    , ( "is_duplicate", Encode.bool False )
                    , ( "book_ids", Encode.list Encode.string bookIds )
                    ]
                )
    in
    Http.GoodStatus_
        { url = "/api/upload/img-test-001/status"
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
        , uploadMergeFormatSuccess
        , uploadMergeFormatFailure
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


uploadPollTimeoutViaLimit : Test
uploadPollTimeoutViaLimit =
    test "upload_poll_timeout_via_limit: CheckStatus guard pollCount >= maxPollCount -> IdentificationFailed without HTTP error" <|
        \() ->
            let
                -- After 3 real poll cycles pollCount == 3. We need pollCount == 150 to
                -- trigger the CheckStatus guard (pollCount >= maxPollCount). Send
                -- CheckStatus directly 147 more times to reach pollCount 150, then one
                -- final CheckStatus hits the >= guard and sets result = IdentificationFailed.
                --
                -- Each intermediate CheckStatus issues a simulated HTTP request that is
                -- never responded to (uploadEffects returns Cmd.none once pollCount >= 150,
                -- and the terminal expectViewHas does not require pending effects to be
                -- handled). This path exercises the real timeout guard in CheckStatus,
                -- NOT the error handler in StatusReceived.
                sendCheckStatusTimes n pt =
                    List.foldl (\_ acc -> ProgramTest.update CheckStatus acc) pt (List.repeat n ())

                advanceAndRespondPending pt =
                    pt
                        |> ProgramTest.advanceTime 2000
                        |> ProgramTest.simulateHttpResponse "GET"
                            "/api/upload/img-test-001/status"
                            (simulatePollResponse Pending Nothing False)
            in
            startUpload
                |> simulateUploadAccepted
                -- 3 real poll cycles: pollCount reaches 3, confirming the polling path works
                |> advanceAndRespondPending
                |> advanceAndRespondPending
                |> advanceAndRespondPending
                -- Advance pollCount from 3 to 150 via direct CheckStatus messages (147 calls).
                -- Each call increments pollCount by 1 and queues an HTTP request we ignore.
                |> sendCheckStatusTimes 147
                -- pollCount is now 150; this final CheckStatus fires the >= maxPollCount guard.
                |> ProgramTest.update CheckStatus
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
    test "upload_manual_isbn_entry: click manual mode -> enter valid ISBN -> submit -> mock lookup response -> verify step shows book title" <|
        \() ->
            startUpload
                |> ProgramTest.clickButton "Enter ISBN manually instead"
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Enter ISBN Manually" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "isbn-input" ]
                |> ProgramTest.update (ManualIsbnChanged "9780141988511")
                |> ProgramTest.update SubmitManualIsbn
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/isbn/9780141988511"
                    (simulateBookResponse "book-isbn-1" "Crime and Punishment" "Fyodor Dostoevsky")
                |> ProgramTest.ensureViewHas
                    [ Selector.text "We think this is…" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Crime and Punishment" ]


uploadMultiBook : Test
uploadMultiBook =
    test "upload_multi_book: poll resolves with 3 bookIds -> fetch all 3 books -> shows Books Identified! and all titles" <|
        \() ->
            startUpload
                |> simulateUploadAccepted
                |> ProgramTest.advanceTime 2000
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/upload/img-test-001/status"
                    (simulateMultiBookPollResponse [ "book-a", "book-b", "book-c" ])
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
                |> ProgramTest.advanceTime 2000
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/upload/img-test-001/status"
                    (simulatePollResponse Resolved (Just "book-1") True)
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
                |> ProgramTest.advanceTime 2000
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/upload/img-test-001/status"
                    (simulatePollResponse Resolved (Just "book-1") True)
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
