module UploadTest exposing (suite)

import Api exposing (PollResponse, PollStatus(..))
import Expect
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Navigation.Route
import Page.Upload as Upload exposing (Msg(..), OutMsg(..), UploadFailure(..), UploadResult(..), UploadStep(..))
import Test exposing (Test, describe, test)
import Types.Book exposing (Book, Edition, VisibilityTier(..))
import Types.Placement exposing (Placement)
import Types.RemoteData exposing (RemoteData(..))


{-| An SSE frame exactly as the server emits it — the one wire shape is
`ProtoJSON.poll_response/1` (snake\_case, all six keys on every branch,
nulls not omissions). Fixtures are built through this helper so a
decoder change that survives these tests is one that survives the real
wire.
-}
serverFrame : String -> Maybe String -> List String -> Maybe String -> String
serverFrame status bookId bookIds rejectionReason =
    let
        orNull =
            Maybe.map Encode.string >> Maybe.withDefault Encode.null
    in
    Encode.encode 0
        (Encode.object
            [ ( "image_id", Encode.string "img-uuid" )
            , ( "status", Encode.string status )
            , ( "book_id", orNull bookId )
            , ( "book_ids", Encode.list Encode.string bookIds )
            , ( "rejection_reason", orNull rejectionReason )
            , ( "is_duplicate", Encode.bool False )
            ]
        )


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


{-| The SSE loop's synthetic timeout frame.

⛔ Was hand-built with `status = Rejected` and never went near the decoder, so
the test named "timeout status…" was in fact exercising a rejection with no
reason attached — a different branch, which happened to land in the same place
back when every failure landed in the same place. It is decoded from a real
frame now, so "timeout" has to survive `Api.streamEventDecoder` to reach the
page (; the same mirror hazard as).

-}
timeoutPoll : PollResponse
timeoutPoll =
    case Decode.decodeString Api.streamEventDecoder (serverFrame "timeout" Nothing [] Nothing) of
        Ok frame ->
            frame

        Err _ ->
            { imageId = "img-1"
            , status = Pending
            , bookId = Nothing
            , bookIds = []
            , rejectionReason = Nothing
            , isDuplicate = False
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
    , verificationSource = "open_library"
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
    , visibility = Nothing
    , hasUserWriting = False
    }


{-| A `POST /api/books/confirm` success body as the page sees it, carrying one
placement per named bookshelf.
-}
confirmResponse : Api.ConfirmOutcome -> List String -> Api.ConfirmResponse
confirmResponse outcome shelfNames =
    let
        placements =
            List.map
                (\name -> { dummyPlacement | id = "p-" ++ name, bookshelfName = Just name })
                shelfNames
    in
    { book = dummyBook
    , placement = List.head placements
    , placements = placements
    , outcome = outcome
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
            [ test "Ok imageId sets uploadState to Success" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (UploadAccepted (Ok "img-1")) Upload.init (Just "tok")
                    in
                    model.uploadState |> Expect.equal (Success "img-1")
            , test "Err sets uploadState to Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (UploadAccepted (Err Http.NetworkError)) Upload.init (Just "tok")
                    in
                    model.uploadState |> Expect.equal (Failure Http.NetworkError)
            ]
        , describe "StreamEvent"
            [ test "resolved payload transitions model to awaiting book fetch" <|
                \_ ->
                    let
                        rawJson =
                            serverFrame "resolved" (Just "some-uuid") [ "some-uuid" ] Nothing

                        ( model, _, _ ) =
                            Upload.update (StreamEvent rawJson) modelWithImage (Just "tok")
                    in
                    model.result |> Expect.equal NoResult
            , test "rejected payload sets result to IdentificationFailed" <|
                \_ ->
                    let
                        rawJson =
                            serverFrame "rejected" Nothing [] (Just "not_a_book")

                        ( model, _, _ ) =
                            Upload.update (StreamEvent rawJson) modelWithImage (Just "tok")
                    in
                    model.result |> Expect.equal NotABook
            , test "heartbeat payload leaves model unchanged" <|
                \_ ->
                    let
                        rawJson =
                            "{\"type\":\"heartbeat\"}"

                        ( model, _, _ ) =
                            Upload.update (StreamEvent rawJson) modelWithImage (Just "tok")
                    in
                    Expect.all
                        [ \m -> m.result |> Expect.equal NoResult
                        , \m -> m.uploadState |> Expect.equal (Success "img-1")
                        ]
                        model
            , test "resolved without bookId sets result to NotABook" <|
                \_ ->
                    let
                        rawJson =
                            serverFrame "resolved" Nothing [] (Just "not_a_book")

                        ( model, _, _ ) =
                            Upload.update (StreamEvent rawJson) modelWithImage (Just "tok")
                    in
                    model.result |> Expect.equal NotABook
            , test "isbn_not_found rejection reason sets result to IdentificationFailed" <|
                \_ ->
                    let
                        rawJson =
                            serverFrame "rejected" Nothing [] (Just "isbn_not_found")

                        ( model, _, _ ) =
                            Upload.update (StreamEvent rawJson) modelWithImage (Just "tok")
                    in
                    model.result |> Expect.equal (IdentificationFailed IsbnUnreadable)
            , test "isbn_not_found rejection clears pendingBookIds and collectedBooks" <|
                \_ ->
                    let
                        base =
                            Upload.init

                        modelInFlight =
                            { base
                                | uploadState = Success "img-1"
                                , pendingBookIds = [ "book-1", "book-2" ]
                                , collectedBooks = [ dummyBook ]
                            }

                        rawJson =
                            serverFrame "rejected" Nothing [] (Just "isbn_not_found")

                        ( model, _, _ ) =
                            Upload.update (StreamEvent rawJson) modelInFlight (Just "tok")
                    in
                    Expect.all
                        [ \m -> m.result |> Expect.equal (IdentificationFailed IsbnUnreadable)
                        , \m -> m.pendingBookIds |> Expect.equal []
                        , \m -> m.collectedBooks |> Expect.equal []
                        ]
                        model
            ]
        , describe "StreamError"
            [ test "StreamError sets result to IdentificationFailed ConnectionLost" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update StreamError modelWithImage (Just "tok")
                    in
                    model.result |> Expect.equal (IdentificationFailed ConnectionLost)
            , test "StreamError leaves uploadState unchanged" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update StreamError modelWithImage (Just "tok")
                    in
                    model.uploadState |> Expect.equal (Success "img-1")
            ]
        , describe "StatusReceived (response-parsing logic, carried over from polling)"
            [ test "timeout status sets result to IdentificationFailed TookTooLong" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Ok timeoutPoll)) modelWithImage (Just "tok")
                    in
                    model.result |> Expect.equal (IdentificationFailed TookTooLong)
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
                            Upload.update (GotIdentifiedBook "book-1" (Ok { book = dummyBook, placement = Nothing, bookshelfVisibility = Nothing, placements = [] })) modelPending Nothing
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
                            Upload.update (GotIdentifiedBook "book-1" (Ok { book = dummyBook, placement = Nothing, bookshelfVisibility = Nothing, placements = [] })) modelPending Nothing
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
                    model.result |> Expect.equal (IdentificationFailed ConnectionLost)
            ]
        , describe "GotDuplicateBook"
            [ test "Ok sets result to DuplicateDetected" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (GotDuplicateBook (Ok { book = dummyBook, placement = Nothing, bookshelfVisibility = Nothing, placements = [] })) Upload.init Nothing
                    in
                    model.result |> Expect.equal (DuplicateDetected dummyBook)
            , test "Err sets result to IdentificationFailed" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (GotDuplicateBook (Err Http.NetworkError)) Upload.init Nothing
                    in
                    model.result |> Expect.equal (IdentificationFailed ConnectionLost)
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
            , test "confirmState is NotAsked" <|
                \_ ->
                    Upload.init.confirmState |> Expect.equal NotAsked
            , test "confirmOutcome is Nothing" <|
                \_ ->
                    Upload.init.confirmOutcome |> Expect.equal Nothing
            , test "mergeFormatState is NotAsked" <|
                \_ ->
                    Upload.init.mergeFormatState |> Expect.equal NotAsked
            , test "manualIsbn is empty" <|
                \_ ->
                    Upload.init.manualIsbn |> Expect.equal ""
            ]
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
                            Upload.update (PlacementCompleted (Err (Api.PlaceHttpError Http.NetworkError))) choosing Nothing
                    in
                    model.placementState |> Expect.equal (Failure (Api.PlaceHttpError Http.NetworkError))
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
            , test "EnterManualMode resets confirmState to NotAsked" <|
                \_ ->
                    let
                        withFailure =
                            { init_ | confirmState = Failure (Api.ConfirmHttpError Http.NetworkError) }

                        ( model, _, _ ) =
                            Upload.update EnterManualMode withFailure Nothing
                    in
                    model.confirmState |> Expect.equal NotAsked
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
            , test "SubmitManualIsbn with valid ISBN sets confirmState to Loading" <|
                \_ ->
                    let
                        withIsbn =
                            { init_ | manualIsbn = "9780306406157" }

                        ( model, _, _ ) =
                            Upload.update SubmitManualIsbn withIsbn (Just "tok")
                    in
                    model.confirmState |> Expect.equal Loading
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
                    model.confirmState |> Expect.equal NotAsked
            , test "ConfirmCompleted Ok created lands on Complete for the chosen shelf" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update
                                (ConfirmCompleted (Ok (confirmResponse Api.ConfirmCreated [])))
                                { init_ | selectedShelf = "library" }
                                Nothing
                    in
                    Expect.all
                        [ \m -> m.result |> Expect.equal (Identified [ dummyBook ])
                        , \m -> m.step |> Expect.equal (Complete dummyBook "library")
                        , \m -> m.confirmState |> Expect.equal (Success ())
                        , \m -> m.confirmOutcome |> Expect.equal (Just Api.ConfirmCreated)
                        ]
                        model
            , test "ConfirmCompleted Ok records the OTHER bookshelves the book is on" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update
                                (ConfirmCompleted
                                    (Ok
                                        (confirmResponse Api.ConfirmPlacedFromCatalogue
                                            [ "library", "wishlist" ]
                                        )
                                    )
                                )
                                { init_ | selectedShelf = "wishlist" }
                                Nothing
                    in
                    model.existingShelves |> Expect.equal [ "library" ]
            , -- #333 — inform, NEVER block: an already-owned book still
              test "ConfirmCompleted Ok on an already-owned book still reaches Complete" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update
                                (ConfirmCompleted
                                    (Ok
                                        (confirmResponse Api.ConfirmPlacedFromCatalogue
                                            [ "library", "wishlist" ]
                                        )
                                    )
                                )
                                { init_ | selectedShelf = "wishlist" }
                                Nothing
                    in
                    Expect.all
                        [ \m -> m.step |> Expect.equal (Complete dummyBook "wishlist")
                        , \m -> m.result |> Expect.equal (Identified [ dummyBook ])
                        , \m -> m.confirmState |> Expect.equal (Success ())
                        ]
                        model
            , -- #333 — a book the reader does not already own leaves the
              test "ConfirmCompleted Ok with only the used shelf records no existing shelves" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update
                                (ConfirmCompleted (Ok (confirmResponse Api.ConfirmCreated [ "wishlist" ])))
                                init_
                                Nothing
                    in
                    model.existingShelves |> Expect.equal []
            , test "ConfirmCompleted merge_required opens the same-work prompt, not an error" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update
                                (ConfirmCompleted (Err (Api.ConfirmMergeRequired "work-1")))
                                { init_ | manualIsbn = "9780156453806" }
                                Nothing
                    in
                    Expect.all
                        [ \m -> m.result |> Expect.equal (SameWorkFound "work-1" Nothing)
                        , \m -> m.mergeIsbn |> Expect.equal "9780156453806"
                        , \m -> m.confirmState |> Expect.equal NotAsked
                        ]
                        model
            , test "GotSameWorkBook Ok fills the prompt's title" <|
                \_ ->
                    let
                        response =
                            { book = dummyBook, placement = Nothing, bookshelfVisibility = Nothing, placements = [] }

                        ( model, _, _ ) =
                            Upload.update
                                (GotSameWorkBook (Ok response))
                                { init_ | result = SameWorkFound "work-1" Nothing }
                                Nothing
                    in
                    model.result |> Expect.equal (SameWorkFound "work-1" (Just dummyBook))
            , -- A failed title fetch degrades the copy; it must not strand the
              test "GotSameWorkBook Err leaves the prompt open without a title" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update
                                (GotSameWorkBook (Err Http.NetworkError))
                                { init_ | result = SameWorkFound "work-1" Nothing }
                                Nothing
                    in
                    model.result |> Expect.equal (SameWorkFound "work-1" Nothing)
            , test "ConfirmCompleted Err sets confirmState to Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update
                                (ConfirmCompleted (Err Api.ConfirmIsbnNotFound))
                                Upload.init
                                Nothing
                    in
                    model.confirmState |> Expect.equal (Failure Api.ConfirmIsbnNotFound)
            ]
        , describe "Duplicate detection"
            [ test "GotDuplicateBook Ok populates mergeIsbn from primaryEdition" <|
                \_ ->
                    let
                        response =
                            { book = dummyBookWithEdition, placement = Nothing, bookshelfVisibility = Nothing, placements = [] }

                        ( model, _, _ ) =
                            Upload.update (GotDuplicateBook (Ok response)) Upload.init Nothing
                    in
                    model.mergeIsbn |> Expect.equal "9780201633610"
            , test "GotDuplicateBook Ok populates mergeFormatLabel from primaryEdition" <|
                \_ ->
                    let
                        response =
                            { book = dummyBookWithEdition, placement = Nothing, bookshelfVisibility = Nothing, placements = [] }

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
            , test "MergeFormatCompleted Ok leaves the duplicate prompt for the completion card" <|
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
                        EditionMerged merged ->
                            Expect.all
                                [ \m -> m.workId |> Expect.equal dummyBook.id
                                , \m -> m.edition |> Expect.equal dummyEdition
                                , \m -> m.onAReaderShelf |> Expect.equal True
                                ]
                                merged

                        _ ->
                            Expect.fail "Expected EditionMerged"
            , test "MergeFormatCompleted Ok from the same-work prompt does not claim a bookshelf" <|
                \_ ->
                    let
                        mergeResponse =
                            { edition = dummyEdition }

                        sameWork =
                            { init_ | result = SameWorkFound "work-1" (Just dummyBook) }

                        ( model, _, _ ) =
                            Upload.update (MergeFormatCompleted (Ok mergeResponse)) sameWork Nothing
                    in
                    case model.result of
                        EditionMerged merged ->
                            Expect.all
                                [ \m -> m.workId |> Expect.equal "work-1"
                                , \m -> m.work |> Expect.equal (Just dummyBook)
                                , \m -> m.onAReaderShelf |> Expect.equal False
                                ]
                                merged

                        _ ->
                            Expect.fail "Expected EditionMerged"
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
