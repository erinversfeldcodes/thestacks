module Page.UploadProgramTest exposing (suite)

{-| Program tests for Page.Upload using elm-program-test.

These tests exercise the full Upload page lifecycle through
simulated user interactions and SSE stream events (replacing the old HTTP polling).

-}

import Api exposing (PollStatus(..))
import Dict
import Http
import Json.Encode as Encode
import Page.Upload as Upload exposing (Msg(..))
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers exposing (simulateBookResponse, simulateMergeFormatResponse, uploadProgram)


{-| Helper to start an upload program with an auth token.
-}
startUpload : ProgramTest.ProgramTest Upload.Model Upload.Msg (ProgramTest.SimulatedEffect Upload.Msg)
startUpload =
    ProgramTest.start () (uploadProgram (Just "test-token"))


{-| Build an SSE stream event JSON string for a given status.
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

        bookIdField =
            case maybeBookId of
                Just bid ->
                    [ ( "bookId", Encode.string bid )
                    , ( "bookIds", Encode.list Encode.string [ bid ] )
                    ]

                Nothing ->
                    [ ( "bookId", Encode.null )
                    , ( "bookIds", Encode.list Encode.string [] )
                    ]
    in
    Encode.encode 0
        (Encode.object
            ([ ( "imageId", Encode.string "img-test-001" )
             , ( "status", Encode.string statusStr )
             , ( "isDuplicate", Encode.bool isDuplicate )
             , ( "rejectionReason", Encode.null )
             ]
                ++ bookIdField
            )
        )


{-| Build an SSE stream event JSON string that resolves with multiple book IDs.
-}
simulateMultiBookStreamEvent : List String -> String
simulateMultiBookStreamEvent bookIds =
    Encode.encode 0
        (Encode.object
            [ ( "imageId", Encode.string "img-test-001" )
            , ( "status", Encode.string "resolved" )
            , ( "isDuplicate", Encode.bool False )
            , ( "bookIds", Encode.list Encode.string bookIds )
            , ( "bookId", Encode.null )
            ]
        )


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
