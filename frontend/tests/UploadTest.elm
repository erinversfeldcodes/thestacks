module UploadTest exposing (suite)

import Api exposing (MergeFormatResponse, PollResponse, PollStatus(..))
import Expect
import Http
import Navigation.Route
import Page.Upload as Upload exposing (Msg(..), OutMsg(..), UploadResult(..), UploadStep(..))
import Test exposing (Test, describe, test)
import Types.Book exposing (Book, Edition, VisibilityTier(..))
import Types.Placement exposing (Placement)
import Types.RemoteData exposing (RemoteData(..))


dummyBook : Book
dummyBook =
    { id = "book-1"
    , title = "Test Book"
    , author = Just { id = "author-1", name = "Test Author", bio = Nothing, website = Nothing }
    , description = Nothing
    , editions = []
    , primaryEdition = Nothing
    , editionCount = 0
    , subjects = []
    , visibilityTier = Public
    }


pendingPoll : PollResponse
pendingPoll =
    { imageId = "img-1"
    , status = Pending
    , bookId = Nothing
    , bookIds = []
    , rejectionReason = Nothing
    , isDuplicate = Nothing
    }


rejectedPoll : PollResponse
rejectedPoll =
    { imageId = "img-1"
    , status = Rejected
    , bookId = Nothing
    , bookIds = []
    , rejectionReason = Just "isbn_not_found"
    , isDuplicate = Nothing
    }


resolvedNewBook : PollResponse
resolvedNewBook =
    { imageId = "img-1"
    , status = Resolved
    , bookId = Just "book-1"
    , bookIds = [ "book-1" ]
    , rejectionReason = Nothing
    , isDuplicate = Just False
    }


resolvedDuplicate : PollResponse
resolvedDuplicate =
    { imageId = "img-1"
    , status = Resolved
    , bookId = Just "book-1"
    , bookIds = [ "book-1" ]
    , rejectionReason = Nothing
    , isDuplicate = Just True
    }


resolvedNotABook : PollResponse
resolvedNotABook =
    { imageId = "img-1"
    , status = Resolved
    , bookId = Nothing
    , bookIds = []
    , rejectionReason = Just "not_a_book"
    , isDuplicate = Nothing
    }


dummyEdition : Edition
dummyEdition =
    { id = "edition-1"
    , isbn = "9780201633610"
    , formatLabel = Just "Hardcover"
    , coverImageUrl = Nothing
    , pageCount = Nothing
    , publisher = Nothing
    , publicationYear = Nothing
    , isPrimary = True
    }


dummyBookWithEdition : Book
dummyBookWithEdition =
    { id = "book-1"
    , title = "Test Book"
    , author = Just { id = "author-1", name = "Test Author", bio = Nothing, website = Nothing }
    , description = Nothing
    , editions = [ dummyEdition ]
    , primaryEdition = Just dummyEdition
    , editionCount = 1
    , subjects = []
    , visibilityTier = Public
    }


dummyPlacement : Placement
dummyPlacement =
    { id = "placement-1"
    , book = Nothing
    , position = Nothing
    , placedAt = Nothing
    , formats = []
    , personalRating = Nothing
    , notes = Nothing
    , bookshelfName = Nothing
    }


modelWithImage : Upload.Model
modelWithImage =
    let
        base =
            Upload.init
    in
    { base | uploadState = Success "img-1" }


suite : Test
suite =
    describe "Page.Upload"
        [ describe "UploadAccepted"
            [ test "Ok imageId sets uploadState to Success and resets pollCount" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (UploadAccepted (Ok "img-1")) Upload.init (Just "tok")
                    in
                    Expect.all
                        [ \m -> m.uploadState |> Expect.equal (Success "img-1")
                        , \m -> m.pollCount |> Expect.equal 0
                        ]
                        model
            , test "Err sets uploadState to Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (UploadAccepted (Err Http.NetworkError)) Upload.init (Just "tok")
                    in
                    model.uploadState |> Expect.equal (Failure Http.NetworkError)
            ]
        , describe "CheckStatus"
            [ test "increments pollCount" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update CheckStatus modelWithImage (Just "tok")
                    in
                    model.pollCount |> Expect.equal 1
            , test "sets result to IdentificationFailed when maxPollCount reached" <|
                \_ ->
                    let
                        base =
                            Upload.init

                        timedOut =
                            { base | uploadState = Success "img-1", pollCount = 150 }

                        ( model, _, _ ) =
                            Upload.update CheckStatus timedOut (Just "tok")
                    in
                    model.result |> Expect.equal IdentificationFailed
            , test "no-ops when uploadState is not Success" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update CheckStatus Upload.init (Just "tok")
                    in
                    model.pollCount |> Expect.equal 0
            , test "no-ops when token is absent" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update CheckStatus modelWithImage Nothing
                    in
                    model.pollCount |> Expect.equal 0
            ]
        , describe "StatusReceived"
            [ test "Pending leaves result unchanged" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Ok pendingPoll)) modelWithImage (Just "tok")
                    in
                    model.result |> Expect.equal NoResult
            , test "Rejected sets result to IdentificationFailed" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Ok rejectedPoll)) Upload.init (Just "tok")
                    in
                    model.result |> Expect.equal IdentificationFailed
            , test "Resolved without bookId sets result to NotABook" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Ok resolvedNotABook)) Upload.init (Just "tok")
                    in
                    model.result |> Expect.equal NotABook
            , test "Resolved with bookId leaves result pending (waits for GotIdentifiedBook)" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Ok resolvedNewBook)) Upload.init (Just "tok")
                    in
                    -- Model unchanged while getBook request is in-flight.
                    model.result |> Expect.equal NoResult
            , test "Resolved with duplicate flag leaves result pending (waits for GotDuplicateBook)" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Ok resolvedDuplicate)) Upload.init (Just "tok")
                    in
                    model.result |> Expect.equal NoResult
            , test "Http error on poll sets result to IdentificationFailed" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Err Http.NetworkError)) Upload.init (Just "tok")
                    in
                    model.result |> Expect.equal IdentificationFailed
            ]
        , describe "GotIdentifiedBook"
            [ test "Ok collects book and enters Verifying step when no more pending" <|
                \_ ->
                    let
                        base =
                            Upload.init

                        modelPending =
                            { base | pendingBookIds = [ "book-1" ], collectedBooks = [] }

                        ( model, _, _ ) =
                            Upload.update (GotIdentifiedBook "book-1" (Ok { book = dummyBook, placement = Nothing })) modelPending Nothing
                    in
                    Expect.all
                        [ \m -> m.result |> Expect.equal (Identified [ dummyBook ])
                        , \m -> m.step |> Expect.equal (Verifying dummyBook)
                        , \m -> m.pendingBookIds |> Expect.equal []
                        ]
                        model
            , test "Ok with remaining pending IDs does not set result to Identified yet" <|
                \_ ->
                    let
                        modelPending =
                            { init_ | pendingBookIds = [ "book-1", "book-2" ], collectedBooks = [] }

                        ( model, _, _ ) =
                            Upload.update (GotIdentifiedBook "book-1" (Ok { book = dummyBook, placement = Nothing })) modelPending Nothing
                    in
                    Expect.all
                        [ \m -> m.pendingBookIds |> Expect.equal [ "book-2" ]
                        , \m -> m.collectedBooks |> Expect.equal [ dummyBook ]
                        , \m -> m.step |> Expect.equal Uploading
                        ]
                        model
            , test "Err sets result to IdentificationFailed when no books collected" <|
                \_ ->
                    let
                        base =
                            Upload.init

                        modelPending =
                            { base | pendingBookIds = [ "book-1" ], collectedBooks = [] }

                        ( model, _, _ ) =
                            Upload.update (GotIdentifiedBook "book-1" (Err Http.NetworkError)) modelPending Nothing
                    in
                    model.result |> Expect.equal IdentificationFailed
            ]
        , describe "GotDuplicateBook"
            [ test "Ok sets result to DuplicateDetected" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (GotDuplicateBook (Ok { book = dummyBook, placement = Nothing })) Upload.init Nothing
                    in
                    model.result |> Expect.equal (DuplicateDetected dummyBook)
            , test "Err sets result to IdentificationFailed" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (GotDuplicateBook (Err Http.NetworkError)) Upload.init Nothing
                    in
                    model.result |> Expect.equal IdentificationFailed
            ]
        , describe "Verification step"
            [ test "ConfirmIdentification moves from Verifying to ChoosingShelf" <|
                \_ ->
                    let
                        base =
                            Upload.init

                        verifying =
                            { base | step = Verifying dummyBook }

                        ( model, _, _ ) =
                            Upload.update ConfirmIdentification verifying Nothing
                    in
                    model.step |> Expect.equal (ChoosingShelf dummyBook)
            , test "RejectIdentification resets to init" <|
                \_ ->
                    let
                        verifying =
                            { init_
                                | step = Verifying dummyBook
                                , result = Identified [ dummyBook ]
                                , uploadState = Success "img-1"
                            }

                        ( model, _, _ ) =
                            Upload.update RejectIdentification verifying Nothing
                    in
                    Expect.all
                        [ \m -> m.step |> Expect.equal Uploading
                        , \m -> m.result |> Expect.equal NoResult
                        , \m -> m.uploadState |> Expect.equal NotAsked
                        ]
                        model
            , test "ShelfSelected updates selectedShelf" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (ShelfSelected "antilibrary") Upload.init Nothing
                    in
                    model.selectedShelf |> Expect.equal "antilibrary"
            , test "default selectedShelf is wishlist" <|
                \_ ->
                    Upload.init.selectedShelf |> Expect.equal "wishlist"
            ]
        , describe "GoToShelf"
            [ test "emits NavigateTo with Library route" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            Upload.update (GoToShelf "library") Upload.init Nothing
                    in
                    outMsg |> Expect.equal (NavigateTo Navigation.Route.Library)
            , test "emits NavigateTo with AntiLibrary route" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            Upload.update (GoToShelf "antilibrary") Upload.init Nothing
                    in
                    outMsg |> Expect.equal (NavigateTo Navigation.Route.AntiLibrary)
            , test "emits NavigateTo with WishList route" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            Upload.update (GoToShelf "wishlist") Upload.init Nothing
                    in
                    outMsg |> Expect.equal (NavigateTo Navigation.Route.WishList)
            , test "unknown shelf falls back to Library route" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            Upload.update (GoToShelf "unknown_shelf") Upload.init Nothing
                    in
                    outMsg |> Expect.equal (NavigateTo Navigation.Route.Library)
            ]
        , describe "init state"
            [ test "step is Uploading" <|
                \_ ->
                    Upload.init.step |> Expect.equal Uploading
            , test "uploadState is NotAsked" <|
                \_ ->
                    Upload.init.uploadState |> Expect.equal NotAsked
            , test "isDragging is False" <|
                \_ ->
                    Upload.init.isDragging |> Expect.equal False
            , test "result is NoResult" <|
                \_ ->
                    Upload.init.result |> Expect.equal NoResult
            , test "placementState is NotAsked" <|
                \_ ->
                    Upload.init.placementState |> Expect.equal NotAsked
            , test "isbnLookupState is NotAsked" <|
                \_ ->
                    Upload.init.isbnLookupState |> Expect.equal NotAsked
            , test "mergeFormatState is NotAsked" <|
                \_ ->
                    Upload.init.mergeFormatState |> Expect.equal NotAsked
            , test "manualIsbn is empty" <|
                \_ ->
                    Upload.init.manualIsbn |> Expect.equal ""
            ]

        -- NOTE: GotFile cannot be tested in pure Elm — File values require
        -- a JS runtime. Use elm-program-test or E2E tests for this branch.
        , describe "DragOver / DragLeave"
            [ test "DragOver sets isDragging to True" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update DragOver Upload.init Nothing
                    in
                    model.isDragging |> Expect.equal True
            , test "DragLeave sets isDragging to False" <|
                \_ ->
                    let
                        dragging =
                            { init_ | isDragging = True }

                        ( model, _, _ ) =
                            Upload.update DragLeave dragging Nothing
                    in
                    model.isDragging |> Expect.equal False
            ]
        , describe "ConfirmPlacement"
            [ test "sets placementState to Loading when in ChoosingShelf with token" <|
                \_ ->
                    let
                        choosing =
                            { init_ | step = ChoosingShelf dummyBook }

                        ( model, _, _ ) =
                            Upload.update ConfirmPlacement choosing (Just "tok")
                    in
                    model.placementState |> Expect.equal Loading
            , test "no-ops when not in ChoosingShelf" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update ConfirmPlacement Upload.init (Just "tok")
                    in
                    model.placementState |> Expect.equal NotAsked
            , test "no-ops when token absent" <|
                \_ ->
                    let
                        choosing =
                            { init_ | step = ChoosingShelf dummyBook }

                        ( model, _, _ ) =
                            Upload.update ConfirmPlacement choosing Nothing
                    in
                    model.placementState |> Expect.equal NotAsked
            ]
        , describe "PlacementCompleted"
            [ test "Ok sets step to Complete with book and shelf" <|
                \_ ->
                    let
                        choosing =
                            { init_
                                | step = ChoosingShelf dummyBook
                                , selectedShelf = "antilibrary"
                            }

                        ( model, _, _ ) =
                            Upload.update (PlacementCompleted (Ok dummyPlacement)) choosing Nothing
                    in
                    model.step |> Expect.equal (Complete dummyBook "antilibrary")
            , test "Err sets placementState to Failure" <|
                \_ ->
                    let
                        choosing =
                            { init_ | step = ChoosingShelf dummyBook }

                        ( model, _, _ ) =
                            Upload.update (PlacementCompleted (Err Http.NetworkError)) choosing Nothing
                    in
                    model.placementState |> Expect.equal (Failure Http.NetworkError)
            ]
        , describe "Reset"
            [ test "resets to init" <|
                \_ ->
                    let
                        modified =
                            { init_
                                | step = ChoosingShelf dummyBook
                                , uploadState = Success "img-1"
                                , selectedShelf = "library"
                                , isDragging = True
                            }

                        ( model, _, _ ) =
                            Upload.update Reset modified Nothing
                    in
                    Expect.all
                        [ \m -> m.step |> Expect.equal Uploading
                        , \m -> m.uploadState |> Expect.equal NotAsked
                        , \m -> m.selectedShelf |> Expect.equal "wishlist"
                        , \m -> m.isDragging |> Expect.equal False
                        , \m -> m.result |> Expect.equal NoResult
                        ]
                        model
            ]
        , describe "Manual ISBN entry"
            [ test "EnterManualMode sets result to ManualISBNEntry" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update EnterManualMode Upload.init Nothing
                    in
                    model.result |> Expect.equal ManualISBNEntry
            , test "EnterManualMode resets isbnLookupState to NotAsked" <|
                \_ ->
                    let
                        withFailure =
                            { init_ | isbnLookupState = Failure Http.NetworkError }

                        ( model, _, _ ) =
                            Upload.update EnterManualMode withFailure Nothing
                    in
                    model.isbnLookupState |> Expect.equal NotAsked
            , test "ManualIsbnChanged updates manualIsbn" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (ManualIsbnChanged "9780201633610") Upload.init Nothing
                    in
                    model.manualIsbn |> Expect.equal "9780201633610"
            , test "ManualIsbnChanged clears showIsbnError" <|
                \_ ->
                    let
                        withError =
                            { init_ | showIsbnError = True }

                        ( model, _, _ ) =
                            Upload.update (ManualIsbnChanged "978") withError Nothing
                    in
                    model.showIsbnError |> Expect.equal False
            , test "SubmitManualIsbn with valid ISBN sets isbnLookupState to Loading" <|
                \_ ->
                    let
                        withIsbn =
                            { init_ | manualIsbn = "9780306406157" }

                        ( model, _, _ ) =
                            Upload.update SubmitManualIsbn withIsbn (Just "tok")
                    in
                    model.isbnLookupState |> Expect.equal Loading
            , test "SubmitManualIsbn with invalid ISBN sets showIsbnError" <|
                \_ ->
                    let
                        withBadIsbn =
                            { init_ | manualIsbn = "1234567890" }

                        ( model, _, _ ) =
                            Upload.update SubmitManualIsbn withBadIsbn (Just "tok")
                    in
                    model.showIsbnError |> Expect.equal True
            , test "SubmitManualIsbn without token does nothing" <|
                \_ ->
                    let
                        withIsbn =
                            { init_ | manualIsbn = "9780306406157" }

                        ( model, _, _ ) =
                            Upload.update SubmitManualIsbn withIsbn Nothing
                    in
                    model.isbnLookupState |> Expect.equal NotAsked
            , test "IsbnLookupResult Ok sets result to Identified and step to Verifying" <|
                \_ ->
                    let
                        response =
                            { book = dummyBook, placement = Nothing }

                        ( model, _, _ ) =
                            Upload.update (IsbnLookupResult (Ok response)) Upload.init Nothing
                    in
                    Expect.all
                        [ \m -> m.result |> Expect.equal (Identified [ dummyBook ])
                        , \m -> m.step |> Expect.equal (Verifying dummyBook)
                        , \m -> m.isbnLookupState |> Expect.equal (Success ())
                        ]
                        model
            , test "IsbnLookupResult Err sets isbnLookupState to Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (IsbnLookupResult (Err Http.NetworkError)) Upload.init Nothing
                    in
                    model.isbnLookupState |> Expect.equal (Failure Http.NetworkError)
            ]
        , describe "Duplicate detection"
            [ test "GotDuplicateBook Ok populates mergeIsbn from primaryEdition" <|
                \_ ->
                    let
                        response =
                            { book = dummyBookWithEdition, placement = Nothing }

                        ( model, _, _ ) =
                            Upload.update (GotDuplicateBook (Ok response)) Upload.init Nothing
                    in
                    model.mergeIsbn |> Expect.equal "9780201633610"
            , test "GotDuplicateBook Ok populates mergeFormatLabel from primaryEdition" <|
                \_ ->
                    let
                        response =
                            { book = dummyBookWithEdition, placement = Nothing }

                        ( model, _, _ ) =
                            Upload.update (GotDuplicateBook (Ok response)) Upload.init Nothing
                    in
                    model.mergeFormatLabel |> Expect.equal "Hardcover"
            , test "SkipMerge converts DuplicateDetected to Identified and enters Verifying" <|
                \_ ->
                    let
                        duplicate =
                            { init_ | result = DuplicateDetected dummyBook }

                        ( model, _, _ ) =
                            Upload.update SkipMerge duplicate Nothing
                    in
                    Expect.all
                        [ \m -> m.result |> Expect.equal (Identified [ dummyBook ])
                        , \m -> m.step |> Expect.equal (Verifying dummyBook)
                        ]
                        model
            , test "SkipMerge no-ops when result is not DuplicateDetected" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update SkipMerge Upload.init Nothing
                    in
                    model.result |> Expect.equal NoResult
            , test "ConfirmMergeFormat sets mergeFormatState to Loading when token present" <|
                \_ ->
                    let
                        dup =
                            { init_
                                | result = DuplicateDetected dummyBook
                                , mergeIsbn = "9780201633610"
                                , mergeFormatLabel = "Hardcover"
                            }

                        ( model, _, _ ) =
                            Upload.update (ConfirmMergeFormat "book-1") dup (Just "tok")
                    in
                    model.mergeFormatState |> Expect.equal Loading
            , test "ConfirmMergeFormat no-ops when token absent" <|
                \_ ->
                    let
                        dup =
                            { init_ | result = DuplicateDetected dummyBook }

                        ( model, _, _ ) =
                            Upload.update (ConfirmMergeFormat "book-1") dup Nothing
                    in
                    model.mergeFormatState |> Expect.equal NotAsked
            , test "MergeFormatCompleted Ok increments editionCount on DuplicateDetected book" <|
                \_ ->
                    let
                        mergeResponse =
                            { edition = dummyEdition }

                        dup =
                            { init_ | result = DuplicateDetected dummyBook }

                        ( model, _, _ ) =
                            Upload.update (MergeFormatCompleted (Ok mergeResponse)) dup Nothing
                    in
                    case model.result of
                        DuplicateDetected book ->
                            book.editionCount |> Expect.equal 1

                        _ ->
                            Expect.fail "Expected DuplicateDetected"
            , test "MergeFormatCompleted Err sets mergeFormatState to Failure" <|
                \_ ->
                    let
                        dup =
                            { init_ | result = DuplicateDetected dummyBook }

                        ( model, _, _ ) =
                            Upload.update (MergeFormatCompleted (Err Http.NetworkError)) dup Nothing
                    in
                    model.mergeFormatState |> Expect.equal (Failure Http.NetworkError)
            ]
        ]


{-| Alias for init to use in record update expressions.
-}
init_ : Upload.Model
init_ =
    Upload.init
