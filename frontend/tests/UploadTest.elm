module UploadTest exposing (suite)

import Api exposing (PollResponse, PollStatus(..))
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
    , readingStatus = Nothing
    , currentPage = Nothing
    , startedAt = Nothing
    , finishedAt = Nothing
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
            [ -- US-1.1.1 | Suite 10: Elm
              test "Ok imageId sets uploadState to Success and resets pollCount" <|
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
            , -- US-1.1.1 | Suite 10: Elm
              test "Err sets uploadState to Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (UploadAccepted (Err Http.NetworkError)) Upload.init (Just "tok")
                    in
                    model.uploadState |> Expect.equal (Failure Http.NetworkError)
            ]
        , describe "CheckStatus"
            [ -- US-1.1.1 | Suite 10: Elm
              test "increments pollCount" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update CheckStatus modelWithImage (Just "tok")
                    in
                    model.pollCount |> Expect.equal 1
            , -- US-1.1.1 | Suite 10: Elm
              test "sets result to IdentificationFailed when maxPollCount reached" <|
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
            , -- US-1.1.1 | Suite 10: Elm
              test "no-ops when uploadState is not Success" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update CheckStatus Upload.init (Just "tok")
                    in
                    model.pollCount |> Expect.equal 0
            , -- US-1.1.1 | Suite 10: Elm
              test "no-ops when token is absent" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update CheckStatus modelWithImage Nothing
                    in
                    model.pollCount |> Expect.equal 0
            ]
        , describe "StatusReceived"
            [ -- US-1.1.1 | Suite 10: Elm
              test "Pending leaves result unchanged" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Ok pendingPoll)) modelWithImage (Just "tok")
                    in
                    model.result |> Expect.equal NoResult
            , -- US-1.1.2 | Suite 10: Elm
              test "Rejected sets result to IdentificationFailed" <|
                \_ ->
                    let
                        withPending =
                            { init_
                                | pendingBookIds = [ "book-1" ]
                                , collectedBooks = [ dummyBook ]
                            }

                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Ok rejectedPoll)) withPending (Just "tok")
                    in
                    Expect.all
                        [ \m -> m.result |> Expect.equal IdentificationFailed
                        , \m -> m.pendingBookIds |> Expect.equal [ "book-1" ]
                        , \m -> m.collectedBooks |> Expect.equal [ dummyBook ]
                        ]
                        model
            , -- US-1.1.3 | Suite 10: Elm
              test "Resolved without bookId sets result to NotABook" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Ok resolvedNotABook)) Upload.init (Just "tok")
                    in
                    model.result |> Expect.equal NotABook
            , -- US-1.1.1 | Suite 10: Elm
              test "Resolved with bookId leaves result pending (waits for GotIdentifiedBook)" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Ok resolvedNewBook)) Upload.init (Just "tok")
                    in
                    -- Model unchanged while getBook request is in-flight.
                    model.result |> Expect.equal NoResult
            , -- US-1.1.6 | Suite 10: Elm
              test "Resolved with duplicate flag leaves result pending (waits for GotDuplicateBook)" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Ok resolvedDuplicate)) Upload.init (Just "tok")
                    in
                    model.result |> Expect.equal NoResult
            , -- US-1.1.1 | Suite 10: Elm
              test "Http error on poll sets result to IdentificationFailed" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Err Http.NetworkError)) Upload.init (Just "tok")
                    in
                    model.result |> Expect.equal IdentificationFailed
            , -- US-1.1.2 | Suite 10: Elm
              test "Http error during rejected poll sets result to IdentificationFailed" <|
                \_ ->
                    let
                        polling =
                            { init_
                                | uploadState = Success "img-1"
                                , pendingBookIds = [ "book-1" ]
                                , collectedBooks = []
                            }

                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Err Http.NetworkError)) polling (Just "tok")
                    in
                    Expect.all
                        [ \m -> m.result |> Expect.equal IdentificationFailed
                        , \m -> m.pendingBookIds |> Expect.equal [ "book-1" ]
                        ]
                        model
            , -- US-1.1.3 | Suite 10: Elm
              test "Http error when expecting not-a-book sets result to IdentificationFailed" <|
                \_ ->
                    let
                        polling =
                            { init_
                                | uploadState = Success "img-1"
                                , pendingBookIds = []
                                , collectedBooks = []
                            }

                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Err Http.NetworkError)) polling (Just "tok")
                    in
                    model.result |> Expect.equal IdentificationFailed
            ]
        , describe "GotIdentifiedBook"
            [ -- US-1.1.1 | Suite 10: Elm
              test "Ok collects book and enters Verifying step when no more pending" <|
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
            , -- US-1.1.7 | Suite 10: Elm
              test "Ok with remaining pending IDs does not set result to Identified yet" <|
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
            , -- US-1.1.1 | Suite 10: Elm
              test "Err sets result to IdentificationFailed when no books collected" <|
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
            [ -- US-1.1.6 | Suite 10: Elm
              test "Ok sets result to DuplicateDetected" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (GotDuplicateBook (Ok { book = dummyBook, placement = Nothing })) Upload.init Nothing
                    in
                    model.result |> Expect.equal (DuplicateDetected dummyBook)
            , -- US-1.1.6 | Suite 10: Elm
              test "Err sets result to IdentificationFailed" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (GotDuplicateBook (Err Http.NetworkError)) Upload.init Nothing
                    in
                    model.result |> Expect.equal IdentificationFailed
            ]
        , describe "Verification step"
            [ -- US-1.1.1 | Suite 10: Elm
              test "ConfirmIdentification moves from Verifying to ChoosingShelf" <|
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
            , -- US-1.1.1 | Suite 10: Elm
              test "RejectIdentification resets to init" <|
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
            , -- US-1.1.1 | Suite 10: Elm
              test "ShelfSelected updates selectedShelf" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (ShelfSelected "antilibrary") Upload.init Nothing
                    in
                    model.selectedShelf |> Expect.equal "antilibrary"
            , -- US-1.1.1 | Suite 10: Elm
              test "default selectedShelf is wishlist" <|
                \_ ->
                    Upload.init.selectedShelf |> Expect.equal "wishlist"
            ]
        , describe "GoToShelf"
            [ -- US-1.1.1 | Suite 10: Elm
              test "emits NavigateTo with Library route" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            Upload.update (GoToShelf "library") Upload.init Nothing
                    in
                    outMsg |> Expect.equal (NavigateTo Navigation.Route.Library)
            , -- US-1.1.1 | Suite 10: Elm
              test "emits NavigateTo with AntiLibrary route" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            Upload.update (GoToShelf "antilibrary") Upload.init Nothing
                    in
                    outMsg |> Expect.equal (NavigateTo Navigation.Route.AntiLibrary)
            , -- US-1.1.1 | Suite 10: Elm
              test "emits NavigateTo with WishList route" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            Upload.update (GoToShelf "wishlist") Upload.init Nothing
                    in
                    outMsg |> Expect.equal (NavigateTo Navigation.Route.WishList)
            , -- US-1.1.1 | Suite 10: Elm
              test "unknown shelf falls back to Library route" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            Upload.update (GoToShelf "unknown_shelf") Upload.init Nothing
                    in
                    outMsg |> Expect.equal (NavigateTo Navigation.Route.Library)
            ]
        , describe "init state"
            [ -- US-1.1.1 | Suite 10: Elm
              test "step is Uploading" <|
                \_ ->
                    Upload.init.step |> Expect.equal Uploading
            , -- US-1.1.1 | Suite 10: Elm
              test "uploadState is NotAsked" <|
                \_ ->
                    Upload.init.uploadState |> Expect.equal NotAsked
            , -- US-1.1.1 | Suite 10: Elm
              test "isDragging is False" <|
                \_ ->
                    Upload.init.isDragging |> Expect.equal False
            , -- US-1.1.1 | Suite 10: Elm
              test "result is NoResult" <|
                \_ ->
                    Upload.init.result |> Expect.equal NoResult
            , -- US-1.1.1 | Suite 10: Elm
              test "placementState is NotAsked" <|
                \_ ->
                    Upload.init.placementState |> Expect.equal NotAsked
            , -- US-1.1.5 | Suite 10: Elm
              test "isbnLookupState is NotAsked" <|
                \_ ->
                    Upload.init.isbnLookupState |> Expect.equal NotAsked
            , -- US-1.1.6, US-1.1.8 | Suite 10: Elm
              test "mergeFormatState is NotAsked" <|
                \_ ->
                    Upload.init.mergeFormatState |> Expect.equal NotAsked
            , -- US-1.1.5 | Suite 10: Elm
              test "manualIsbn is empty" <|
                \_ ->
                    Upload.init.manualIsbn |> Expect.equal ""
            ]

        -- NOTE: GotFile cannot be tested in pure Elm — File values require
        -- a JS runtime. Use elm-program-test or E2E tests for this branch.
        , describe "DragOver / DragLeave"
            [ -- US-1.1.1 | Suite 10: Elm
              test "DragOver sets isDragging to True" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update DragOver Upload.init Nothing
                    in
                    model.isDragging |> Expect.equal True
            , -- US-1.1.1 | Suite 10: Elm
              test "DragLeave sets isDragging to False" <|
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
            [ -- US-1.1.1 | Suite 10: Elm
              test "sets placementState to Loading when in ChoosingShelf with token" <|
                \_ ->
                    let
                        choosing =
                            { init_ | step = ChoosingShelf dummyBook }

                        ( model, _, _ ) =
                            Upload.update ConfirmPlacement choosing (Just "tok")
                    in
                    model.placementState |> Expect.equal Loading
            , -- US-1.1.1 | Suite 10: Elm
              test "no-ops when not in ChoosingShelf" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update ConfirmPlacement Upload.init (Just "tok")
                    in
                    model.placementState |> Expect.equal NotAsked
            , -- US-1.1.1 | Suite 10: Elm
              test "no-ops when token absent" <|
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
            [ -- US-1.1.1 | Suite 10: Elm
              test "Ok sets step to Complete with book and shelf" <|
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
            , -- US-1.1.1 | Suite 10: Elm
              test "Err sets placementState to Failure" <|
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
            [ -- US-1.1.1 | Suite 10: Elm
              test "resets to init" <|
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
            [ -- US-1.1.5 | Suite 10: Elm
              test "EnterManualMode sets result to ManualISBNEntry" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update EnterManualMode Upload.init Nothing
                    in
                    model.result |> Expect.equal ManualISBNEntry
            , -- US-1.1.5 | Suite 10: Elm
              test "EnterManualMode resets isbnLookupState to NotAsked" <|
                \_ ->
                    let
                        withFailure =
                            { init_ | isbnLookupState = Failure Http.NetworkError }

                        ( model, _, _ ) =
                            Upload.update EnterManualMode withFailure Nothing
                    in
                    model.isbnLookupState |> Expect.equal NotAsked
            , -- US-1.1.5 | Suite 10: Elm
              test "ManualIsbnChanged updates manualIsbn" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (ManualIsbnChanged "9780201633610") Upload.init Nothing
                    in
                    model.manualIsbn |> Expect.equal "9780201633610"
            , -- US-1.1.5 | Suite 10: Elm
              test "ManualIsbnChanged clears showIsbnError" <|
                \_ ->
                    let
                        withError =
                            { init_ | showIsbnError = True }

                        ( model, _, _ ) =
                            Upload.update (ManualIsbnChanged "978") withError Nothing
                    in
                    model.showIsbnError |> Expect.equal False
            , -- US-1.1.5 | Suite 10: Elm
              test "SubmitManualIsbn with valid ISBN sets isbnLookupState to Loading" <|
                \_ ->
                    let
                        withIsbn =
                            { init_ | manualIsbn = "9780306406157" }

                        ( model, _, _ ) =
                            Upload.update SubmitManualIsbn withIsbn (Just "tok")
                    in
                    model.isbnLookupState |> Expect.equal Loading
            , -- US-1.1.5 | Suite 10: Elm
              test "SubmitManualIsbn with invalid ISBN sets showIsbnError" <|
                \_ ->
                    let
                        withBadIsbn =
                            { init_ | manualIsbn = "1234567890" }

                        ( model, _, _ ) =
                            Upload.update SubmitManualIsbn withBadIsbn (Just "tok")
                    in
                    model.showIsbnError |> Expect.equal True
            , -- US-1.1.5 | Suite 10: Elm
              test "SubmitManualIsbn without token does nothing" <|
                \_ ->
                    let
                        withIsbn =
                            { init_ | manualIsbn = "9780306406157" }

                        ( model, _, _ ) =
                            Upload.update SubmitManualIsbn withIsbn Nothing
                    in
                    model.isbnLookupState |> Expect.equal NotAsked
            , -- US-1.1.5 | Suite 10: Elm
              test "IsbnLookupResult Ok sets result to Identified and step to Verifying" <|
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
            , -- US-1.1.5 | Suite 10: Elm
              test "IsbnLookupResult Err sets isbnLookupState to Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (IsbnLookupResult (Err Http.NetworkError)) Upload.init Nothing
                    in
                    model.isbnLookupState |> Expect.equal (Failure Http.NetworkError)
            ]
        , describe "Duplicate detection"
            [ -- US-1.1.6, US-1.1.8 | Suite 10: Elm
              test "GotDuplicateBook Ok populates mergeIsbn from primaryEdition" <|
                \_ ->
                    let
                        response =
                            { book = dummyBookWithEdition, placement = Nothing }

                        ( model, _, _ ) =
                            Upload.update (GotDuplicateBook (Ok response)) Upload.init Nothing
                    in
                    model.mergeIsbn |> Expect.equal "9780201633610"
            , -- US-1.1.6, US-1.1.8 | Suite 10: Elm
              test "GotDuplicateBook Ok populates mergeFormatLabel from primaryEdition" <|
                \_ ->
                    let
                        response =
                            { book = dummyBookWithEdition, placement = Nothing }

                        ( model, _, _ ) =
                            Upload.update (GotDuplicateBook (Ok response)) Upload.init Nothing
                    in
                    model.mergeFormatLabel |> Expect.equal "Hardcover"
            , -- US-1.1.6 | Suite 10: Elm
              test "SkipMerge converts DuplicateDetected to Identified and enters Verifying" <|
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
            , -- US-1.1.6 | Suite 10: Elm
              test "SkipMerge no-ops when result is not DuplicateDetected" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update SkipMerge Upload.init Nothing
                    in
                    model.result |> Expect.equal NoResult
            , -- US-1.1.6, US-1.1.8 | Suite 10: Elm
              test "ConfirmMergeFormat sets mergeFormatState to Loading when token present" <|
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
            , -- US-1.1.6, US-1.1.8 | Suite 10: Elm
              test "ConfirmMergeFormat no-ops when token absent" <|
                \_ ->
                    let
                        dup =
                            { init_ | result = DuplicateDetected dummyBook }

                        ( model, _, _ ) =
                            Upload.update (ConfirmMergeFormat "book-1") dup Nothing
                    in
                    model.mergeFormatState |> Expect.equal NotAsked
            , -- US-1.1.6, US-1.1.8 | Suite 10: Elm
              test "MergeFormatCompleted Ok increments editionCount on DuplicateDetected book" <|
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
            , -- US-1.1.6, US-1.1.8 | Suite 10: Elm
              test "MergeFormatCompleted Err sets mergeFormatState to Failure" <|
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
