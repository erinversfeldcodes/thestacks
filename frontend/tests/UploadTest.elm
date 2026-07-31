module UploadTest exposing (suite)

import Api exposing (PollResponse, PollStatus(..))
import Expect
import Http
import Json.Encode as Encode
import Navigation.Route
import Page.Upload as Upload exposing (Msg(..), OutMsg(..), UploadResult(..), UploadStep(..))
import Test exposing (Test, describe, test)
import Types.Book exposing (Book, Edition, VisibilityTier(..))
import Types.Placement exposing (Placement)
import Types.RemoteData exposing (RemoteData(..))


{-| An SSE frame exactly as the server emits it.

The one and only wire shape is `StacksWeb.ProtoJSON.poll_response/1`
(`apps/core/lib/stacks_web/proto_json.ex:525-534`), declared by
`proto/stacks/common/v1/upload.proto`'s `PollResponse`. It is snake\_case, and
`UploadController.sse_receive_loop/4` passes all six keys on every branch —
`book_ids` defaults to `[]` and `is_duplicate` to `false` server-side, and
`book_id` / `rejection_reason` are serialized as JSON `null` rather than
omitted. Building every fixture through here means a wire rename has exactly
one place to be wrong, and it is the place that fails.

Until Issue #328 these frames were written by hand in camelCase — a shape the
server has never emitted — so breaking any production wire field left the suite
green.

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


timeoutPoll : PollResponse
timeoutPoll =
    { imageId = "img-1"
    , status = Rejected
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
            [ -- US-1.1.1 | Suite 10: Elm
              test "Ok imageId sets uploadState to Success" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (UploadAccepted (Ok "img-1")) Upload.init (Just "tok")
                    in
                    model.uploadState |> Expect.equal (Success "img-1")
            , -- US-1.1.1 | Suite 10: Elm
              test "Err sets uploadState to Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (UploadAccepted (Err Http.NetworkError)) Upload.init (Just "tok")
                    in
                    model.uploadState |> Expect.equal (Failure Http.NetworkError)
            ]
        , describe "StreamEvent"
            [ -- US-1.1.1 | Suite 10: Elm (#160 SSE)
              test "resolved payload transitions model to awaiting book fetch" <|
                \_ ->
                    let
                        rawJson =
                            serverFrame "resolved" (Just "some-uuid") [ "some-uuid" ] Nothing

                        ( model, _, _ ) =
                            Upload.update (StreamEvent rawJson) modelWithImage (Just "tok")
                    in
                    -- Model is in-flight fetching book; result stays NoResult while
                    -- GotIdentifiedBook request is pending.
                    model.result |> Expect.equal NoResult
            , -- US-1.1.2 | Suite 10: Elm (#160 SSE)
              test "rejected payload sets result to IdentificationFailed" <|
                \_ ->
                    let
                        rawJson =
                            serverFrame "rejected" Nothing [] (Just "not_a_book")

                        ( model, _, _ ) =
                            Upload.update (StreamEvent rawJson) modelWithImage (Just "tok")
                    in
                    -- rejection reason "not_a_book" → NotABook result
                    model.result |> Expect.equal NotABook
            , -- US-1.1.1 | Suite 10: Elm (#160 SSE)
              test "heartbeat payload leaves model unchanged" <|
                \_ ->
                    let
                        rawJson =
                            "{\"type\":\"heartbeat\"}"

                        ( model, _, _ ) =
                            Upload.update (StreamEvent rawJson) modelWithImage (Just "tok")
                    in
                    -- heartbeat should not alter result or uploadState
                    Expect.all
                        [ \m -> m.result |> Expect.equal NoResult
                        , \m -> m.uploadState |> Expect.equal (Success "img-1")
                        ]
                        model
            , -- US-1.1.2 | Suite 10: Elm (#160 SSE)
              test "resolved without bookId sets result to NotABook" <|
                \_ ->
                    let
                        rawJson =
                            serverFrame "resolved" Nothing [] (Just "not_a_book")

                        ( model, _, _ ) =
                            Upload.update (StreamEvent rawJson) modelWithImage (Just "tok")
                    in
                    model.result |> Expect.equal NotABook
            , -- US-1.1.2 | Suite 10: Elm (#160 SSE)
              test "isbn_not_found rejection reason sets result to IdentificationFailed" <|
                \_ ->
                    let
                        rawJson =
                            serverFrame "rejected" Nothing [] (Just "isbn_not_found")

                        ( model, _, _ ) =
                            Upload.update (StreamEvent rawJson) modelWithImage (Just "tok")
                    in
                    model.result |> Expect.equal IdentificationFailed
            , -- US-1.1.2 | Suite 10: Elm (#160 SSE)
              -- Regression guard: pending IDs and collected books must be cleared on
              -- rejection so that a retry starts from a clean slate rather than
              -- inheriting stale state from the previous attempt.
              test "isbn_not_found rejection clears pendingBookIds and collectedBooks" <|
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
                        [ \m -> m.result |> Expect.equal IdentificationFailed
                        , \m -> m.pendingBookIds |> Expect.equal []
                        , \m -> m.collectedBooks |> Expect.equal []
                        ]
                        model
            ]
        , describe "StreamError"
            [ -- US-1.1.1 | Suite 10: Elm (#160 SSE)
              test "StreamError sets result to IdentificationFailed" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update StreamError modelWithImage (Just "tok")
                    in
                    model.result |> Expect.equal IdentificationFailed
            , -- US-1.1.1 | Suite 10: Elm (#160 SSE)
              test "StreamError leaves uploadState unchanged" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update StreamError modelWithImage (Just "tok")
                    in
                    -- uploadState stays as-is; only result changes
                    model.uploadState |> Expect.equal (Success "img-1")
            ]
        , describe "StatusReceived (response-parsing logic, carried over from polling)"
            [ -- US-1.1.2 | Suite 10: Elm
              test "timeout status sets result to IdentificationFailed" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Ok timeoutPoll)) modelWithImage (Just "tok")
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
                            Upload.update (GotIdentifiedBook "book-1" (Ok { book = dummyBook, placement = Nothing, bookshelfVisibility = Nothing, placements = [] })) modelPending Nothing
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
                            Upload.update (GotIdentifiedBook "book-1" (Ok { book = dummyBook, placement = Nothing, bookshelfVisibility = Nothing, placements = [] })) modelPending Nothing
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
                            Upload.update (GotDuplicateBook (Ok { book = dummyBook, placement = Nothing, bookshelfVisibility = Nothing, placements = [] })) Upload.init Nothing
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
              test "confirmState is NotAsked" <|
                \_ ->
                    Upload.init.confirmState |> Expect.equal NotAsked
            , -- US-1.1.5 | Suite 10: Elm
              test "confirmOutcome is Nothing" <|
                \_ ->
                    Upload.init.confirmOutcome |> Expect.equal Nothing
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
                            Upload.update (PlacementCompleted (Err (Api.PlaceHttpError Http.NetworkError))) choosing Nothing
                    in
                    model.placementState |> Expect.equal (Failure (Api.PlaceHttpError Http.NetworkError))
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
              test "EnterManualMode resets confirmState to NotAsked" <|
                \_ ->
                    let
                        withFailure =
                            { init_ | confirmState = Failure (Api.ConfirmHttpError Http.NetworkError) }

                        ( model, _, _ ) =
                            Upload.update EnterManualMode withFailure Nothing
                    in
                    model.confirmState |> Expect.equal NotAsked
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
              test "SubmitManualIsbn with valid ISBN sets confirmState to Loading" <|
                \_ ->
                    let
                        withIsbn =
                            { init_ | manualIsbn = "9780306406157" }

                        ( model, _, _ ) =
                            Upload.update SubmitManualIsbn withIsbn (Just "tok")
                    in
                    model.confirmState |> Expect.equal Loading
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
                    model.confirmState |> Expect.equal NotAsked
            , -- US-1.1.5 | Suite 10: Elm — `Books.confirm/2` created the work,
              -- its primary edition and the placement in one transaction, so
              -- the manual path lands on the completion card. There is no
              -- intervening verification step: the reader typed the ISBN.
              test "ConfirmCompleted Ok created lands on Complete for the chosen shelf" <|
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
            , -- US-1.1.6 / #333 | Suite 10: Elm — the duplicate notice. The
              -- confirm response reports EVERY bookshelf the reader has this
              -- book on; the ones other than the shelf just used are the
              -- notice.
              test "ConfirmCompleted Ok records the OTHER bookshelves the book is on" <|
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
              -- completes the add. If this ever diverges, the notice has
              -- become a gate.
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
              -- notice empty; so does the shelf this very request used.
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
            , -- US-1.1.8 | Suite 10: Elm — the 409 is an OUTCOME, not a
              -- failure. It must not land in confirmState as an error, or the
              -- reader is told to check a number that was correct.
              test "ConfirmCompleted merge_required opens the same-work prompt, not an error" <|
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
            , -- US-1.1.8 | Suite 10: Elm — the work is fetched only to name it.
              test "GotSameWorkBook Ok fills the prompt's title" <|
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
              -- reader on a screen with no merge button.
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
            , -- US-1.1.5 | Suite 10: Elm
              test "ConfirmCompleted Err sets confirmState to Failure" <|
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
            [ -- US-1.1.6, US-1.1.8 | Suite 10: Elm
              test "GotDuplicateBook Ok populates mergeIsbn from primaryEdition" <|
                \_ ->
                    let
                        response =
                            { book = dummyBookWithEdition, placement = Nothing, bookshelfVisibility = Nothing, placements = [] }

                        ( model, _, _ ) =
                            Upload.update (GotDuplicateBook (Ok response)) Upload.init Nothing
                    in
                    model.mergeIsbn |> Expect.equal "9780201633610"
            , -- US-1.1.6, US-1.1.8 | Suite 10: Elm
              test "GotDuplicateBook Ok populates mergeFormatLabel from primaryEdition" <|
                \_ ->
                    let
                        response =
                            { book = dummyBookWithEdition, placement = Nothing, bookshelfVisibility = Nothing, placements = [] }

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
            , -- US-1.1.6, US-1.1.8 | Suite 10: Elm | #355
              --
              -- The transition itself, at the level the screen is decided. The
              -- test this replaces asserted `editionCount` had been bumped on a
              -- still-`DuplicateDetected` result — i.e. it pinned the merge
              -- staying inside the prompt, which is the defect.
              test "MergeFormatCompleted Ok leaves the duplicate prompt for the completion card" <|
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

                                -- The photo path only offers a merge because
                                -- the book is already on one of this reader's
                                -- bookshelves (`is_duplicate`).
                                , \m -> m.onAReaderShelf |> Expect.equal True
                                ]
                                merged

                        _ ->
                            Expect.fail "Expected EditionMerged"
            , -- US-1.1.8 | Suite 10: Elm | #355
              test "MergeFormatCompleted Ok from the same-work prompt does not claim a bookshelf" <|
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

                                -- `confirm/2` answered 409 before placing
                                -- anything, and a merge places nothing.
                                , \m -> m.onAReaderShelf |> Expect.equal False
                                ]
                                merged

                        _ ->
                            Expect.fail "Expected EditionMerged"
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
