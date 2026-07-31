module Page.Upload exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , UploadResult(..)
    , UploadStep(..)
    , init
    , update
    , view
    )

import Api exposing (BookDetailResponse, MergeFormatResponse, PollResponse, PollStatus(..))
import Components.ISBNInput exposing (isValidISBN, isbnInput)
import File exposing (File)
import File.Select as Select
import Html exposing (Html, a, button, div, h1, h2, img, input, label, li, p, span, text, ul)
import Html.Attributes exposing (alt, attribute, checked, class, href, src, type_)
import Html.Events exposing (onCheck, onClick, preventDefaultOn)
import Http
import Json.Decode as Decode
import Navigation.Route as Route
import Types.Book exposing (Book, Edition, VisibilityTier(..), authorName, bookCoverImageUrl, bookIsbn, displayTitle, isProvisional)
import Types.Placement exposing (Placement)
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


type UploadResult
    = NoResult
    | Identified (List Book)
    | IdentificationFailed
    | NotABook
    | ManualISBNEntry
    | DuplicateDetected Book
      -- `Books.confirm/2` answered 409 `merge_required`: the ISBN resolved to a
      -- title+author that fuzzy-matches a work we already hold, so it refused
      -- to mint a second one and named the work to merge into (US-1.1.8). The
      -- id is that work; the `Maybe Book` is it once fetched, purely so the
      -- prompt can name the title. The prompt renders either way — a failed
      -- fetch degrades the copy, it does not strand the reader.
    | SameWorkFound String (Maybe Book)
      -- The server accepted a merge (#355). Terminal, and deliberately a
      -- separate result rather than a `Success` branch inside the two prompts:
      -- while the merge lived inside the prompt, answering "Yes, merge" left
      -- the heading, the question and the buttons on screen with a line of
      -- confirmation threaded between them, so a reader who had just changed
      -- the catalogue was still being asked whether they wanted to. The prompt
      -- is a question; once it is answered it should not still be on screen.
    | EditionMerged MergedEdition


{-| What the completion card is allowed to say, and where each part comes from.

`edition` is the SERVER's answer — the row it actually wrote — so the card names
an ISBN and format that exist rather than a client-side guess. (The card this
replaces said `"X" now has N editions`, computed as `book.editionCount + 1` from
a book the client had fetched earlier: a number that is wrong the moment anyone
else merged, and that was being read off the very cache #355 found stale.)

`onAReaderShelf` is the difference between the two ways in, and it is why this
is a record and not just a work id. The photo path only shows a merge prompt
because `is_duplicate` said the book is already on one of this reader's
bookshelves. The manual path is the opposite: `confirm/2` answered 409 _before_
placing anything, and merging an edition places nothing either — so that reader
does not own this book, and a card that let them assume otherwise would be the
same untruth #333 removed from the confirm path.

-}
type alias MergedEdition =
    { workId : String
    , work : Maybe Book
    , edition : Edition
    , onAReaderShelf : Bool
    }


{-| The step within the upload flow after a book has been identified.
-}
type UploadStep
    = Uploading
    | Verifying Book
    | ChoosingShelf Book
    | Complete Book String


type alias Model =
    { file : Maybe File

    -- Loading = upload in flight; Success imageId = upload accepted, SSE stream in progress.
    , uploadState : RemoteData Http.Error String
    , result : UploadResult
    , manualIsbn : String
    , showIsbnError : Bool
    , isDragging : Bool
    , duplicateShelf : String
    , duplicateMoveState : RemoteData Http.Error ()

    -- Accumulate multiple book fetches before showing the result.
    , pendingBookIds : List String
    , collectedBooks : List Book

    -- Multi-book partial-failure tracking: book IDs whose fetch failed.
    -- Used to render a "Could not identify" placeholder per failed book
    -- in the identified list, alongside the successfully fetched books.
    , failedBookIds : List String

    -- Verification step state machine
    , step : UploadStep
    , selectedShelf : String
    , placementState : RemoteData Api.PlaceError Placement

    -- User "adults only" (age-gate raise) toggle for the book being placed.
    -- When True, ConfirmPlacement also fires the raise-only user age-gate
    -- endpoint. `ageGateError` surfaces a soft failure that must NOT block
    -- the placement itself.
    , markAdultsOnly : Bool
    , ageGateError : Maybe String

    -- Server-provided runtime flag (ADR-020). When `False` (production
    -- default) every age-gating affordance in the upload flow is hidden —
    -- the "adults only" checkbox, the age-gate notice — and confirming a
    -- placement never fires the raise-only age-gate call.
    , ageGatingEnabled : Bool

    -- Manual-entry confirm state (#343). The manual path is one round trip
    -- through `POST /api/books/confirm`, so this covers resolving, creating and
    -- placing together — there is no separate lookup state to be in.
    , confirmState : RemoteData Api.ConfirmError ()

    -- Which branch of `Books.confirm/2` answered the manual add, so the
    -- completion card can say "added to" rather than "already on" (and vice
    -- versa) instead of guessing. `Nothing` on the photo path, which does not
    -- go through the verb.
    , confirmOutcome : Maybe Api.ConfirmOutcome

    -- Bookshelves this book is ALREADY on for this reader, other than the one
    -- this action just used (#333). Purely informational — it is rendered as a
    -- notice and never gates a confirm or a placement, since a book on several
    -- bookshelves is a legal state the reader may well want.
    , existingShelves : List String

    -- Merge format flow
    , mergeFormatState : RemoteData Http.Error MergeFormatResponse
    , mergeIsbn : String
    , mergeFormatLabel : String

    -- True once a terminal SSE event (resolved/rejected) has been received.
    -- Used to suppress spurious StreamError after the server closes the connection.
    , sseTerminalReceived : Bool

    -- Cumulative list of book IDs the user has rejected via "No, try again"
    -- for the current image upload. Reset on Reset or a successful Confirm.
    -- The server uses this list to exclude already-rejected books from the
    -- vision pipeline's next pass.
    , rejectedBookIds : List String
    }


type OutMsg
    = NoOut
    | NavigateTo Route.Route
    | OpenStream String
    | SessionExpired


type Msg
    = GotFile File
    | DragOver
    | DragLeave
    | FilepickerRequested
    | UploadInitialised File String (Result Http.Error Api.UploadInit)
    | R2PutCompleted String String (Result Http.Error ())
    | UploadAccepted (Result Http.Error String)
    | StatusReceived (Result Http.Error PollResponse)
    | StreamEvent String
    | StreamError
    | GotIdentifiedBook String (Result Http.Error BookDetailResponse)
    | GotDuplicateBook (Result Http.Error BookDetailResponse)
    | ManualIsbnChanged String
    | SubmitManualIsbn
    | EnterManualMode
    | ConfirmMergeFormat String
    | SkipMerge
    | MergeFormatCompleted (Result Http.Error MergeFormatResponse)
    | Reset
    | ConfirmIdentification
    | RejectIdentification
    | RejectIdentificationCompleted (Result Http.Error ())
    | ShelfSelected String
    | ToggleAdultsOnly
    | ConfirmPlacement
    | PlacementCompleted (Result Api.PlaceError Placement)
    | AgeGateSet (Result Http.Error ())
    | ConfirmCompleted (Result Api.ConfirmError Api.ConfirmResponse)
    | GotSameWorkBook (Result Http.Error BookDetailResponse)
    | GoToShelf String


init : Model
init =
    { file = Nothing
    , uploadState = NotAsked
    , result = NoResult
    , manualIsbn = ""
    , showIsbnError = False
    , isDragging = False
    , duplicateShelf = "library"
    , duplicateMoveState = NotAsked
    , pendingBookIds = []
    , collectedBooks = []
    , failedBookIds = []
    , step = Uploading
    , selectedShelf = "wishlist"
    , placementState = NotAsked
    , markAdultsOnly = False
    , ageGateError = Nothing
    , ageGatingEnabled = False
    , confirmState = NotAsked
    , confirmOutcome = Nothing
    , existingShelves = []
    , mergeFormatState = NotAsked
    , mergeIsbn = ""
    , mergeFormatLabel = ""
    , sseTerminalReceived = False
    , rejectedBookIds = []
    }


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        GotFile file ->
            case maybeToken of
                Nothing ->
                    -- Not authenticated — send to login rather than silently hanging.
                    ( { model | file = Just file, isDragging = False }
                    , Cmd.none
                    , NoOut
                    )

                Just token ->
                    -- Three-step presigned-URL flow:
                    --   1. Init: ask backend for an image_id + presigned R2 PUT URL.
                    --   2. PUT the file bytes directly to R2 (bypasses Phoenix).
                    --   3. Commit: tell backend the PUT landed; backend enqueues
                    --      the vision pipeline and we open the SSE stream.
                    ( { model
                        | file = Just file
                        , uploadState = Loading
                        , isDragging = False
                        , step = Uploading
                      }
                    , Api.initUpload
                        (File.mime file)
                        token
                        (UploadInitialised file token)
                    , NoOut
                    )

        UploadInitialised _ _ (Err err) ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
                ( { model | uploadState = Failure Http.NetworkError }, Cmd.none, NoOut )

        UploadInitialised file token (Ok init_) ->
            ( model
            , Api.putFileToR2 init_.uploadUrl file (R2PutCompleted init_.imageId token)
            , NoOut
            )

        R2PutCompleted _ _ (Err _) ->
            ( { model | uploadState = Failure Http.NetworkError }, Cmd.none, NoOut )

        R2PutCompleted imageId token (Ok ()) ->
            ( model
            , Api.commitUpload imageId token UploadAccepted
            , NoOut
            )

        DragOver ->
            ( { model | isDragging = True }, Cmd.none, NoOut )

        DragLeave ->
            ( { model | isDragging = False }, Cmd.none, NoOut )

        FilepickerRequested ->
            ( model, Select.files [ "image/*" ] (\f _ -> GotFile f), NoOut )

        UploadAccepted result ->
            case result of
                Ok imageId ->
                    -- Upload accepted; open SSE stream for identification result.
                    case maybeToken of
                        Just token ->
                            ( { model | uploadState = Success imageId }
                            , Cmd.none
                            , OpenStream ("/api/upload/" ++ imageId ++ "/stream?token=" ++ token)
                            )

                        Nothing ->
                            ( { model | uploadState = Success imageId }, Cmd.none, NoOut )

                Err err ->
                    ( { model | uploadState = Failure err }, Cmd.none, NoOut )

        StatusReceived result ->
            case result of
                Ok response ->
                    case response.status of
                        Resolved ->
                            let
                                -- Prefer the book_ids array; fall back to singleton book_id.
                                ids =
                                    if List.isEmpty response.bookIds then
                                        case response.bookId of
                                            Just bid ->
                                                [ bid ]

                                            Nothing ->
                                                []

                                    else
                                        response.bookIds
                            in
                            case ( ids, maybeToken ) of
                                ( [], _ ) ->
                                    -- Resolved without any book IDs means not_a_book.
                                    ( { model | result = NotABook }, Cmd.none, NoOut )

                                ( [ singleId ], Just token ) ->
                                    -- Single book: check for duplicate, then fetch.
                                    let
                                        callback =
                                            if response.isDuplicate then
                                                GotDuplicateBook

                                            else
                                                GotIdentifiedBook singleId
                                    in
                                    ( { model | pendingBookIds = [], collectedBooks = [], failedBookIds = [], sseTerminalReceived = True }
                                    , Api.getBook singleId (Just token) callback
                                    , NoOut
                                    )

                                ( multiIds, Just token ) ->
                                    -- Multiple books: fetch all in parallel.
                                    ( { model
                                        | pendingBookIds = multiIds
                                        , collectedBooks = []
                                        , failedBookIds = []
                                        , sseTerminalReceived = True
                                      }
                                    , Cmd.batch
                                        (List.map
                                            (\bid -> Api.getBook bid (Just token) (GotIdentifiedBook bid))
                                            multiIds
                                        )
                                    , NoOut
                                    )

                                _ ->
                                    ( { model | result = NotABook, sseTerminalReceived = True }, Cmd.none, NoOut )

                        Rejected ->
                            case response.rejectionReason of
                                Just "not_a_book" ->
                                    ( { model | result = NotABook, pendingBookIds = [], collectedBooks = [], failedBookIds = [], sseTerminalReceived = True }, Cmd.none, NoOut )

                                _ ->
                                    ( { model | result = IdentificationFailed, pendingBookIds = [], collectedBooks = [], failedBookIds = [], sseTerminalReceived = True }, Cmd.none, NoOut )

                        Pending ->
                            ( model, Cmd.none, NoOut )

                Err _ ->
                    ( { model | result = IdentificationFailed }, Cmd.none, NoOut )

        StreamEvent rawJson ->
            case Decode.decodeString Api.streamEventDecoder rawJson of
                Ok pollResponse ->
                    update (StatusReceived (Ok pollResponse)) model maybeToken

                Err _ ->
                    -- Malformed event (e.g. heartbeat) — ignore, stay in current state.
                    ( model, Cmd.none, NoOut )

        StreamError ->
            -- Ignore the error if we already received a terminal SSE event.
            -- When the server closes the connection immediately after sending
            -- resolved/rejected, the browser fires onerror right after the
            -- message — before book fetches complete. The flag prevents that
            -- connection-close error from overwriting the correct pipeline state.
            if model.sseTerminalReceived then
                ( model, Cmd.none, NoOut )

            else
                ( { model | result = IdentificationFailed }, Cmd.none, NoOut )

        GotIdentifiedBook bookId result ->
            case result of
                Ok response ->
                    let
                        book =
                            response.book

                        newCollected =
                            model.collectedBooks ++ [ book ]

                        remaining =
                            List.filter (\bid -> bid /= bookId) model.pendingBookIds
                    in
                    if List.isEmpty remaining then
                        -- All books fetched — enter Verifying step for single book,
                        -- or show multi-book list for multiple.
                        case newCollected of
                            [ singleBook ] ->
                                ( { model
                                    | result = Identified newCollected
                                    , collectedBooks = []
                                    , pendingBookIds = []
                                    , step = Verifying singleBook

                                    -- The photo path gets the same "already
                                    -- yours" notice the manual path does: the
                                    -- book-detail response has carried every
                                    -- placement since #333, and the verify step
                                    -- is the last moment before a second copy
                                    -- is filed. Informational — "Yes, that's
                                    -- it" stays enabled.
                                    , existingShelves =
                                        List.filterMap .bookshelfName response.placements
                                  }
                                , Cmd.none
                                , NoOut
                                )

                            _ ->
                                ( { model
                                    | result = Identified newCollected
                                    , collectedBooks = []
                                    , pendingBookIds = []

                                    -- The multi-book list has no notice to
                                    -- carry; clearing keeps a previous book's
                                    -- shelves from surfacing on a later step.
                                    , existingShelves = []
                                  }
                                , Cmd.none
                                , NoOut
                                )

                    else
                        ( { model
                            | collectedBooks = newCollected
                            , pendingBookIds = remaining
                          }
                        , Cmd.none
                        , NoOut
                        )

                Err _ ->
                    -- One book fetch failed — remove from pending and remember
                    -- the failed ID so the multi-book identified view can render
                    -- a "Could not identify" placeholder for it. Show what we
                    -- have if everything else is done, otherwise keep waiting.
                    let
                        remaining =
                            List.filter (\bid -> bid /= bookId) model.pendingBookIds

                        newFailed =
                            model.failedBookIds ++ [ bookId ]
                    in
                    if List.isEmpty remaining then
                        case model.collectedBooks of
                            [] ->
                                ( { model | result = IdentificationFailed, failedBookIds = newFailed }, Cmd.none, NoOut )

                            books ->
                                ( { model
                                    | result = Identified books
                                    , collectedBooks = []
                                    , pendingBookIds = []
                                    , failedBookIds = newFailed
                                  }
                                , Cmd.none
                                , NoOut
                                )

                    else
                        ( { model | pendingBookIds = remaining, failedBookIds = newFailed }, Cmd.none, NoOut )

        GotDuplicateBook result ->
            case result of
                Ok response ->
                    let
                        isbn =
                            response.book.primaryEdition
                                |> Maybe.map .isbn
                                |> Maybe.withDefault ""

                        formatLabel =
                            response.book.primaryEdition
                                |> Maybe.andThen .formatLabel
                                |> Maybe.withDefault "Unknown"
                    in
                    ( { model
                        | result = DuplicateDetected response.book
                        , mergeIsbn = isbn
                        , mergeFormatLabel = formatLabel
                      }
                    , Cmd.none
                    , NoOut
                    )

                Err _ ->
                    ( { model | result = IdentificationFailed }, Cmd.none, NoOut )

        ManualIsbnChanged isbn ->
            ( { model | manualIsbn = isbn, showIsbnError = False }, Cmd.none, NoOut )

        -- The manual path is now ONE hop (#343). It used to be
        -- `GET /api/books/isbn/:isbn` for metadata and then
        -- `POST /api/bookshelves/:name/placements` to file it — a client-side
        -- reassembly of `Books.confirm/2` that was missing the middle step the
        -- verb has and the client cannot do: resolving the ISBN against Open
        -- Library / Google Books. Without it, a perfectly good ISBN the
        -- catalogue had never seen came back 404 and the reader was told to
        -- check a number that was correct.
        SubmitManualIsbn ->
            if isValidISBN model.manualIsbn then
                case maybeToken of
                    Just token ->
                        ( { model | confirmState = Loading, existingShelves = [] }
                        , Api.confirmBook
                            { isbn = model.manualIsbn, shelfName = model.selectedShelf }
                            token
                            ConfirmCompleted
                        , NoOut
                        )

                    Nothing ->
                        ( model, Cmd.none, NoOut )

            else
                ( { model | showIsbnError = True }, Cmd.none, NoOut )

        ConfirmCompleted (Ok response) ->
            ( { model
                | confirmState = Success ()
                , confirmOutcome = Just response.outcome
                , result = Identified [ response.book ]
                , step = Complete response.book model.selectedShelf

                -- Inform, never block: the verb has already done the work, and
                -- the completion card reports every OTHER bookshelf this book
                -- is on so a second copy is never a surprise. Nothing here can
                -- refuse anything — the placement exists by the time we render.
                , existingShelves = otherShelves model.selectedShelf response.placements
              }
            , Cmd.none
            , NoOut
            )

        ConfirmCompleted (Err (Api.ConfirmMergeRequired workId)) ->
            -- US-1.1.8. Not a failure: the server declined to mint a second
            -- work and told us which one this is an edition of. Fetch it only
            -- so the prompt can name the title.
            ( { model
                | confirmState = NotAsked
                , result = SameWorkFound workId Nothing
                , mergeIsbn = model.manualIsbn
                , mergeFormatState = NotAsked
              }
            , case maybeToken of
                Just token ->
                    Api.getBook workId (Just token) GotSameWorkBook

                Nothing ->
                    Cmd.none
            , NoOut
            )

        ConfirmCompleted (Err (Api.ConfirmHttpError err)) ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
                ( { model | confirmState = Failure (Api.ConfirmHttpError err) }, Cmd.none, NoOut )

        ConfirmCompleted (Err confirmError) ->
            ( { model | confirmState = Failure confirmError }, Cmd.none, NoOut )

        GotSameWorkBook result ->
            case ( result, model.result ) of
                ( Ok response, SameWorkFound workId _ ) ->
                    ( { model | result = SameWorkFound workId (Just response.book) }
                    , Cmd.none
                    , NoOut
                    )

                _ ->
                    -- The prompt already renders without a title; a failed
                    -- fetch just leaves the generic copy in place.
                    ( model, Cmd.none, NoOut )

        EnterManualMode ->
            ( { model | result = ManualISBNEntry, confirmState = NotAsked }, Cmd.none, NoOut )

        ConfirmMergeFormat bookId ->
            case maybeToken of
                Just token ->
                    ( { model | mergeFormatState = Loading }
                    , Api.mergeFormat bookId
                        { isbn = model.mergeIsbn, formatLabel = model.mergeFormatLabel }
                        token
                        MergeFormatCompleted
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        SkipMerge ->
            -- User chose "No, add as separate" — proceed to normal shelf picker.
            case model.result of
                DuplicateDetected book ->
                    ( { model
                        | result = Identified [ book ]
                        , step = Verifying book
                      }
                    , Cmd.none
                    , NoOut
                    )

                _ ->
                    ( model, Cmd.none, NoOut )

        MergeFormatCompleted result ->
            case result of
                Ok response ->
                    ( { model
                        | mergeFormatState = Success response
                        , result = mergeCompletionFor response.edition model.result
                      }
                    , Cmd.none
                    , NoOut
                    )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | mergeFormatState = Failure err }, Cmd.none, NoOut )

        Reset ->
            ( init, Cmd.none, NoOut )

        ConfirmIdentification ->
            case model.step of
                Verifying book ->
                    ( { model | step = ChoosingShelf book }, Cmd.none, NoOut )

                _ ->
                    ( model, Cmd.none, NoOut )

        RejectIdentification ->
            case ( model.step, model.uploadState, maybeToken ) of
                ( Verifying book, Success imageId, Just token ) ->
                    let
                        newRejected =
                            model.rejectedBookIds ++ [ book.id ]
                    in
                    ( { model
                        | rejectedBookIds = newRejected
                        , step = Uploading
                        , result = NoResult
                        , pendingBookIds = []
                        , collectedBooks = []
                        , failedBookIds = []
                        , placementState = NotAsked
                        , sseTerminalReceived = False
                      }
                    , Api.rejectIdentification
                        { imageId = imageId
                        , rejectedBookIds = newRejected
                        , token = token
                        }
                        RejectIdentificationCompleted
                    , OpenStream ("/api/upload/" ++ imageId ++ "/stream?token=" ++ token)
                    )

                _ ->
                    -- No image / no token / not in Verifying step — fall back to
                    -- the legacy full reset so we never wedge in a half-state.
                    ( init, Cmd.none, NoOut )

        RejectIdentificationCompleted result ->
            case result of
                Ok () ->
                    -- The HTTP 202 only acknowledges the request. The SSE stream
                    -- is the real signal source for the re-run vision pipeline.
                    ( model, Cmd.none, NoOut )

                Err _ ->
                    -- The server didn't accept the rejection. Surface the
                    -- failure on the same screen the user would see on a
                    -- pipeline failure rather than wedging in the spinner.
                    ( { model | result = IdentificationFailed }, Cmd.none, NoOut )

        ShelfSelected shelf ->
            ( { model | selectedShelf = shelf }, Cmd.none, NoOut )

        ToggleAdultsOnly ->
            ( { model | markAdultsOnly = not model.markAdultsOnly }, Cmd.none, NoOut )

        ConfirmPlacement ->
            case ( model.step, maybeToken ) of
                ( ChoosingShelf book, Just token ) ->
                    -- Place the book, and (if the user marked it "adults only")
                    -- fire the raise-only user age-gate endpoint alongside. A
                    -- failure of the age-gate call must not block placement, so
                    -- both run together and the age-gate result is handled
                    -- softly in AgeGateSet.
                    let
                        ageGateCmd =
                            if model.ageGatingEnabled && model.markAdultsOnly then
                                [ Api.setBookAgeGate book.id token AgeGateSet ]

                            else
                                []
                    in
                    ( { model | placementState = Loading, ageGateError = Nothing }
                    , Cmd.batch
                        (Api.placeBook model.selectedShelf book.id token PlacementCompleted
                            :: ageGateCmd
                        )
                    , NoOut
                    )

                _ ->
                    ( model, Cmd.none, NoOut )

        AgeGateSet result ->
            case result of
                Ok () ->
                    ( model, Cmd.none, NoOut )

                Err _ ->
                    -- Soft failure: the book was still placed. Surface a gentle
                    -- notice rather than failing the whole flow.
                    ( { model | ageGateError = Just "We couldn't mark this book as adults only. You can change it later from the book's page." }
                    , Cmd.none
                    , NoOut
                    )

        PlacementCompleted result ->
            case ( result, model.step ) of
                ( Ok _, ChoosingShelf book ) ->
                    ( { model
                        | step = Complete book model.selectedShelf
                        , placementState = Success placementStub
                        , rejectedBookIds = []
                      }
                    , Cmd.none
                    , NoOut
                    )

                ( Err Api.PlaceReadingPileFull, _ ) ->
                    ( { model | placementState = Failure Api.PlaceReadingPileFull }, Cmd.none, NoOut )

                ( Err (Api.PlaceHttpError err), _ ) ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | placementState = Failure (Api.PlaceHttpError err) }, Cmd.none, NoOut )

                _ ->
                    ( model, Cmd.none, NoOut )

        GoToShelf shelfName ->
            ( model, Cmd.none, NavigateTo (shelfRoute shelfName) )


{-| Minimal placement stub — only used to track success state.
-}
placementStub : Placement
placementStub =
    { id = ""
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


view : Model -> Maybe String -> Html Msg
view model maybeToken =
    div [ class "page page--upload" ]
        [ h1 [ class "page__title" ] [ text "Add a Book" ]
        , div [ attribute "aria-live" "polite", class "upload-status-region" ]
            [ case maybeToken of
                Nothing ->
                    viewSignInRequired

                Just _ ->
                    case model.step of
                        Verifying book ->
                            viewVerifying model.ageGatingEnabled model.existingShelves book

                        ChoosingShelf book ->
                            viewChoosingShelf model book

                        Complete book shelfName ->
                            viewComplete model book shelfName

                        Uploading ->
                            case model.result of
                                NoResult ->
                                    viewUploadArea model

                                Identified books ->
                                    viewIdentified books model.failedBookIds

                                IdentificationFailed ->
                                    viewIdentificationFailed

                                NotABook ->
                                    viewNotABook

                                ManualISBNEntry ->
                                    viewManualEntry model

                                DuplicateDetected book ->
                                    viewDuplicate model book

                                SameWorkFound workId maybeBook ->
                                    viewSameWork model workId maybeBook

                                EditionMerged merged ->
                                    viewEditionMerged merged
            ]
        ]


viewSignInRequired : Html Msg
viewSignInRequired =
    div [ class "upload-auth-required", testId "upload-auth-required" ]
        [ p [] [ text "You need to sign in to add books." ]
        , a [ href "/login", class "btn btn--primary" ] [ text "Sign In" ]
        ]


viewUploadArea : Model -> Html Msg
viewUploadArea model =
    let
        draggingClass =
            if model.isDragging then
                "upload-area upload-area--dragging"

            else
                "upload-area"

        onDropDecoder =
            Decode.at [ "dataTransfer", "files" ]
                (Decode.map GotFile
                    (Decode.index 0 File.decoder)
                )

        onDrop_ =
            preventDefaultOn "drop" (Decode.map (\m -> ( m, True )) onDropDecoder)

        onDragOver_ =
            preventDefaultOn "dragover" (Decode.succeed ( DragOver, True ))

        onDragLeave_ =
            preventDefaultOn "dragleave" (Decode.succeed ( DragLeave, True ))
    in
    div []
        [ div
            [ class draggingClass
            , testId "upload-drop-zone"
            , onDrop_
            , onDragOver_
            , onDragLeave_
            ]
            [ case model.uploadState of
                Loading ->
                    div [ class "upload-area__loading", testId "upload-loading", attribute "role" "status" ]
                        [ span [ class "spinner" ] []
                        , p [] [ text "Processing image..." ]
                        ]

                Success _ ->
                    div [ class "upload-area__loading", testId "upload-loading", attribute "role" "status" ]
                        [ span [ class "spinner" ] []
                        , p [] [ text "Processing image..." ]
                        ]

                Failure _ ->
                    div [ class "upload-area__error", testId "upload-error" ]
                        [ p [] [ text "Upload failed. Please try again." ]
                        , button [ class "btn btn--primary", onClick Reset ]
                            [ text "Try Again" ]
                        ]

                NotAsked ->
                    viewDropPrompt
            ]
        , div [ class "upload-manual-link" ]
            [ button
                [ class "btn btn--ghost"
                , onClick EnterManualMode
                ]
                [ text "Enter ISBN manually instead" ]
            ]
        ]


viewDropPrompt : Html Msg
viewDropPrompt =
    div [ class "upload-area__prompt" ]
        [ p [ class "upload-area__icon" ] [ text "📷" ]
        , p [] [ text "Drag a photo of a book cover here" ]
        , p [ class "upload-area__or" ] [ text "or" ]
        , button
            [ class "btn btn--primary"
            , onClick FilepickerRequested
            ]
            [ text "Choose Photo" ]
        ]


viewIdentified : List Book -> List String -> Html Msg
viewIdentified books failedBookIds =
    let
        totalCount =
            List.length books + List.length failedBookIds

        heading =
            if totalCount == 1 then
                "Book Identified!"

            else
                "Books Identified!"
    in
    div [ class "upload-result upload-result--identified", attribute "role" "status", testId "upload-identified" ]
        ([ h2 [] [ text heading ]
         , ul [ class "upload-result__book-list" ]
            (List.map viewIdentifiedBook books
                ++ List.map viewUnidentifiedPlaceholder failedBookIds
            )
         ]
            ++ [ button [ class "btn btn--ghost", onClick Reset ] [ text "Try Another" ] ]
        )


viewIdentifiedBook : Book -> Html Msg
viewIdentifiedBook book =
    li [ class "upload-result__book-item" ]
        [ p [ class "upload-result__book-title" ] [ text (displayTitle book) ]
        , viewProvisionalNoticeIfNeeded book
        , p [ class "upload-result__book-author" ] [ text (authorName book) ]
        , a
            [ href (Route.toPath (Route.BookDetail book.id))
            , class "btn btn--primary"
            ]
            [ text "View Book" ]
        ]


{-| Render a placeholder list item for a book whose fetch failed during a
multi-book upload. The user still sees the resolved books and can act on
them; this row makes the partial failure visible without blocking the
overall result.
-}
viewUnidentifiedPlaceholder : String -> Html Msg
viewUnidentifiedPlaceholder _ =
    li
        [ class "upload-result__book-item upload-result__book-item--unidentified"
        , testId "upload-unidentified-placeholder"
        ]
        [ p [ class "upload-result__book-title" ] [ text "Could not identify" ]
        , p [ class "upload-result__book-author" ]
            [ text "We couldn't load this book. You can still place the others." ]
        ]


viewIdentificationFailed : Html Msg
viewIdentificationFailed =
    div [ class "upload-result upload-result--failed", testId "upload-error" ]
        [ h2 [] [ text "Could Not Identify Book" ]
        , p []
            [ text
                "We couldn't read the ISBN from this photo. Try a clearer image or enter the ISBN manually."
            ]
        , button [ class "btn btn--primary", onClick Reset ] [ text "Try Another Photo" ]
        , button [ class "btn btn--secondary", onClick EnterManualMode ]
            [ text "Enter ISBN Manually" ]
        ]


viewNotABook : Html Msg
viewNotABook =
    div [ class "upload-result upload-result--not-book", testId "upload-error" ]
        [ h2 [] [ text "That Doesn't Look Like a Book" ]
        , p []
            [ text
                "We couldn't detect a book in that image. Please try a photo of a book cover."
            ]
        , button [ class "btn btn--primary", onClick Reset ] [ text "Try Again" ]
        , button [ class "btn btn--secondary", onClick EnterManualMode ]
            [ text "Enter ISBN Manually" ]
        ]


{-| Manual ISBN entry (US-1.1.5), now a single screen and a single request.

The bookshelf is chosen here rather than on a later step because
`Books.confirm/2` creates and places in one transaction — asking afterwards
would mean either placing on a shelf the reader never picked or filing the book
twice. There is no intervening "We think this is…" step either: that exists on
the photo path because a vision model GUESSED, and the resolved title is shown
on the completion card. The reader typed the ISBN; the ISBN is the identity.

-}
viewManualEntry : Model -> Html Msg
viewManualEntry model =
    div [ class "upload-result upload-result--manual" ]
        [ h2 [] [ text "Enter ISBN Manually" ]
        , isbnInput
            { value = model.manualIsbn
            , onInput = ManualIsbnChanged
            , showError = model.showIsbnError
            }
        , viewShelfChoices model.selectedShelf
        , case model.confirmState of
            Loading ->
                div [ class "upload-manual__loading" ]
                    [ span [ class "spinner" ] []
                    , p [] [ text "Adding your book..." ]
                    ]

            Failure confirmError ->
                div [ class "upload-manual__error" ]
                    [ p [ class "upload-manual__error-text" ]
                        [ text (confirmErrorMessage confirmError) ]
                    , viewManualSubmit model.selectedShelf
                    ]

            _ ->
                viewManualSubmit model.selectedShelf
        , button [ class "btn btn--ghost", onClick Reset ] [ text "Cancel" ]
        ]


viewManualSubmit : String -> Html Msg
viewManualSubmit selectedShelf =
    button
        [ class "btn btn--primary"
        , testId "upload-manual-isbn-submit"
        , onClick SubmitManualIsbn
        ]
        [ text ("Add to " ++ shelfLabel selectedShelf) ]


{-| A wrong ISBN and a broken server are different problems and get different
sentences — the old copy said "check the ISBN" for both, which was actively
misleading for the case this issue exists to fix (a correct ISBN the catalogue
simply had never seen). `ConfirmMergeRequired` never reaches here: it is an
outcome with its own screen, not a failure.
-}
confirmErrorMessage : Api.ConfirmError -> String
confirmErrorMessage confirmError =
    case confirmError of
        Api.ConfirmIsbnNotFound ->
            "We couldn't find a book with that ISBN. Please check the number and try again."

        Api.ConfirmMergeRequired _ ->
            "This looks like another edition of a book we already have."

        Api.ConfirmHttpError _ ->
            "We couldn't add that book just now. Please try again."


{-| "We've got the barcode but haven't matched it to a book yet."

The barcode fast path deliberately skips the Open Library / Google Books
round-trip on the upload hot path, so a book can be legitimately shelved before
anything knows its title. Until enrichment lands, the server's stand-in title is
the ISBN — and rendered as a title it reads as a book actually named after a
number, which is a bug, a rare book, and a pending lookup all at once, with no
way for the reader to tell which.

Two rules this notice keeps, both deliberate:

  - It says what happened to the BOOK, not what the reader did wrong. The ISBN
    gate passed; a provisional book is a legal state, not a rejected one.
  - It informs and stops. No button below it is disabled and no step is skipped
    — the standing owner ruling, and the same shape as the duplicate notices.

-}
viewProvisionalNoticeIfNeeded : Book -> Html Msg
viewProvisionalNoticeIfNeeded book =
    if isProvisional book then
        p
            [ class "upload-provisional-notice"
            , testId "upload-provisional-notice"
            , attribute "role" "status"
            ]
            [ text
                ("We read the barcode ("
                    ++ bookIsbn book
                    ++ ") but haven't matched it to a catalogue record yet. "
                    ++ "The title and cover will fill in shortly — you can shelve it now."
                )
            ]

    else
        text ""


{-| Render an in-flow age-gate notice when the resolved book is
age-gated AND age-gating is enabled (ADR-020). Per US-1.1.4 the upload
flow proceeds normally for the identification step, but the user is
informed that the book is age-restricted. There is no self-serve
"verify age" action anymore (verification is provider-sourced, shipped
in a later issue), so the notice is informational only. When age-gating
is disabled — the production default — nothing is rendered.
-}
viewAgeGateNoticeIfNeeded : Bool -> Book -> Html Msg
viewAgeGateNoticeIfNeeded ageGatingEnabled book =
    case ( ageGatingEnabled, book.visibilityTier ) of
        ( True, AgeGated ) ->
            div
                [ class "upload-verify__age-gate-notice"
                , testId "upload-age-gate-notice"
                , attribute "role" "status"
                ]
                [ p [ class "upload-verify__age-gate-message" ]
                    [ text "This book has been marked as age-gated. Age verification is required to view its details." ]
                ]

        _ ->
            text ""


{-| "You already have this on your Library shelf." — the manual-ISBN duplicate
notice (#333).

The photo path has told the reader about a duplicate since the SSE payload's
`is_duplicate`; typing the ISBN by hand told them nothing at all, so a second
placement happened silently. This informs and then gets out of the way: no
button is disabled, no step is skipped, and a book on two bookshelves is a
state the reader is allowed to want. `looking_for_home` is included here (it
is still "you already have this"), unlike the book-detail multi-shelf notice,
whose job is tidying up duplicate _collection_ entries.

-}
viewExistingShelvesNotice : List String -> Html Msg
viewExistingShelvesNotice shelfNames =
    case List.map shelfLabel shelfNames of
        [] ->
            text ""

        labels ->
            p
                [ class "upload-verify__already-yours"
                , testId "upload-already-yours"
                ]
                [ text ("You already have this on your " ++ joinWithAnd labels ++ ".") ]


{-| The same notice on the completion card (#343). The manual path learns the
reader's other bookshelves from the confirm response, which by definition
arrives after the placement — so this is where it can be said. Same wording,
same muted register; still nothing but a sentence.
-}
viewCompleteExistingShelvesNotice : List String -> Html Msg
viewCompleteExistingShelvesNotice shelfNames =
    case List.map shelfLabel shelfNames of
        [] ->
            text ""

        labels ->
            p
                [ class "upload-complete__already-yours"
                , testId "upload-already-yours"
                ]
                [ text ("You already have this on your " ++ joinWithAnd labels ++ ".") ]


{-| Every bookshelf the reader has this book on EXCEPT the one this action just
used — that one is already named in the heading, so repeating it would read as
a duplicate that isn't one.
-}
otherShelves : String -> List Placement -> List String
otherShelves usedShelf placements =
    placements
        |> List.filterMap .bookshelfName
        |> List.filter (\name -> name /= usedShelf)


{-| The screen a merge lands on (#355), given the prompt it was answered from.

Both prompts that offer "Yes, merge" end in the same completion card, but only
one of them means the reader has this book: see `MergedEdition`. Anything else
is a merge with no prompt behind it, which nothing can produce — leaving the
result untouched keeps that unreachable case from inventing a screen.

-}
mergeCompletionFor : Edition -> UploadResult -> UploadResult
mergeCompletionFor edition result =
    case result of
        DuplicateDetected book ->
            EditionMerged
                { workId = book.id
                , work = Just book
                , edition = edition
                , onAReaderShelf = True
                }

        SameWorkFound workId maybeBook ->
            EditionMerged
                { workId = workId
                , work = maybeBook
                , edition = edition
                , onAReaderShelf = False
                }

        other ->
            other


{-| How a heading names the book it is about.

A quoted title is how you refer to a book by name, so it is only used when the
book has one. A provisional book does not — quoting `Not yet identified` would
present a status as if it were the title, which is the same untruth as quoting
the ISBN. `this book` is what a person would say.

-}
headingSubject : Book -> String
headingSubject book =
    if isProvisional book then
        "This book"

    else
        "\"" ++ book.title ++ "\""


{-| The heading for each branch of `Books.confirm/2`.
-}
completeHeading : Maybe Api.ConfirmOutcome -> Book -> String -> String
completeHeading outcome book shelfName =
    case outcome of
        Just Api.ConfirmAlreadyPlaced ->
            headingSubject book ++ " is already on your " ++ shelfLabel shelfName

        _ ->
            headingSubject book ++ " added to " ++ shelfLabel shelfName


{-| "A", "A and B", "A, B and C".
-}
joinWithAnd : List String -> String
joinWithAnd labels =
    case List.reverse labels of
        [] ->
            ""

        [ only ] ->
            only

        last :: rest ->
            String.join ", " (List.reverse rest) ++ " and " ++ last


{-| Verification step: "We think this is..." with confirm/reject.
-}
viewVerifying : Bool -> List String -> Book -> Html Msg
viewVerifying ageGatingEnabled existingShelves book =
    div [ class "upload-verify", testId "upload-verify" ]
        [ h2 [ class "upload-verify__heading" ] [ text "We think this is…" ]
        , viewExistingShelvesNotice existingShelves
        , viewProvisionalNoticeIfNeeded book
        , viewAgeGateNoticeIfNeeded ageGatingEnabled book
        , div [ class "upload-verify__content" ]
            [ div [ class "upload-verify__book-info" ]
                [ case bookCoverImageUrl book of
                    Just coverUrl ->
                        img
                            [ src coverUrl
                            , alt (book.title ++ " cover")
                            , class "upload-verify__cover"
                            ]
                            []

                    Nothing ->
                        div [ class "upload-verify__cover upload-verify__cover--placeholder" ]
                            [ text "No cover" ]
                , div [ class "upload-verify__details" ]
                    [ p [ class "upload-verify__title" ] [ text (displayTitle book) ]
                    , p [ class "upload-verify__author" ] [ text (authorName book) ]
                    ]
                ]
            ]
        , div [ class "upload-verify__actions" ]
            [ button
                [ class "btn btn--primary"
                , testId "upload-confirm-btn"
                , onClick ConfirmIdentification
                ]
                [ text "Yes, that's it" ]
            , button
                [ class "btn btn--secondary"
                , testId "upload-reject-btn"
                , onClick RejectIdentification
                ]
                [ text "No, try again" ]
            ]
        ]


allShelves : List { value : String, label : String }
allShelves =
    [ { value = "library", label = "Library" }
    , { value = "antilibrary", label = "Antilibrary" }
    , { value = "wishlist", label = "Wish List" }
    , { value = "reading_pile", label = "Reading Pile" }
    , { value = "looking_for_home", label = "Looking for a Home" }
    ]


{-| Shelf picker step: choose which bookshelf to place the book on.
-}
viewChoosingShelf : Model -> Book -> Html Msg
viewChoosingShelf model book =
    div [ class "upload-shelf-picker", testId "upload-shelf-picker" ]
        [ h2 [ class "upload-shelf-picker__heading" ]
            [ text ("Add " ++ headingSubject book ++ " to a shelf") ]

        -- Still informational at the moment of choosing (#333) — every shelf
        -- stays selectable, including ones the book is already on.
        , viewExistingShelvesNotice model.existingShelves

        -- Every shelf stays selectable for a provisional book too: the ISBN gate
        -- passed, only the lookup is outstanding.
        , viewProvisionalNoticeIfNeeded book
        , viewShelfChoices model.selectedShelf
        , if model.ageGatingEnabled then
            viewAdultsOnlyToggle model.markAdultsOnly

          else
            text ""
        , case model.placementState of
            Loading ->
                div [ class "upload-shelf-picker__loading" ]
                    [ span [ class "spinner" ] []
                    , p [] [ text "Adding to shelf..." ]
                    ]

            Failure Api.PlaceReadingPileFull ->
                div [ class "upload-shelf-picker__error", testId "reading-pile-full-msg" ]
                    [ p [] [ text "Your reading pile is full — finish or remove a book before adding another." ]
                    , button
                        [ class "btn btn--primary"
                        , onClick ConfirmPlacement
                        ]
                        [ text ("Add to " ++ shelfLabel model.selectedShelf) ]
                    ]

            Failure (Api.PlaceHttpError _) ->
                div [ class "upload-shelf-picker__error" ]
                    [ p [] [ text "Failed to add book. Please try again." ]
                    , button
                        [ class "btn btn--primary"
                        , onClick ConfirmPlacement
                        ]
                        [ text ("Add to " ++ shelfLabel model.selectedShelf) ]
                    ]

            _ ->
                button
                    [ class "btn btn--primary"
                    , onClick ConfirmPlacement
                    ]
                    [ text ("Add to " ++ shelfLabel model.selectedShelf) ]
        , button [ class "btn btn--ghost", onClick Reset ] [ text "Cancel" ]
        ]


{-| The five bookshelves, as a row of selectable buttons. Shared by the shelf
picker (photo path) and the manual-entry screen (#343) so the two ways of
adding a book offer the same choice in the same markup.
-}
viewShelfChoices : String -> Html Msg
viewShelfChoices selectedShelf =
    div [ class "upload-shelf-picker__shelves" ]
        (List.map
            (\shelf ->
                button
                    [ class
                        (if shelf.value == selectedShelf then
                            "upload-shelf-picker__shelf upload-shelf-picker__shelf--selected"

                         else
                            "upload-shelf-picker__shelf"
                        )
                    , onClick (ShelfSelected shelf.value)
                    ]
                    [ text shelf.label ]
            )
            allShelves
        )


{-| "Adults only" (age-gate raise) opt-in checkbox shown on the shelf
picker. When ticked, ConfirmPlacement additionally fires the raise-only
user age-gate endpoint for the book being placed.
-}
viewAdultsOnlyToggle : Bool -> Html Msg
viewAdultsOnlyToggle isChecked =
    div [ class "upload-adults-only" ]
        [ label [ class "upload-adults-only__label" ]
            [ input
                [ type_ "checkbox"
                , checked isChecked
                , onCheck (\_ -> ToggleAdultsOnly)
                , testId "upload-adults-only"
                ]
                []
            , span [] [ text "Mark as adults only (18+)" ]
            ]
        , p [ class "upload-adults-only__hint" ]
            [ text "Hides this book from readers who haven't confirmed they're 18+." ]
        ]


{-| Success step: book placed on shelf.

The heading distinguishes `Books.confirm/2`'s `:already_placed` branch from the
two that changed something. Saying "added to your Wish List" when the book was
already sitting there is the same class of untruth as the pre-#333 silent
second placement — the reader must be able to tell what actually happened.
`Nothing` is the photo path, which places directly and always added.

-}
viewComplete : Model -> Book -> String -> Html Msg
viewComplete model book shelfName =
    div [ class "upload-complete", testId "upload-complete", attribute "role" "status" ]
        [ h2 [ class "upload-complete__heading" ]
            [ text (completeHeading model.confirmOutcome book shelfName) ]

        -- Inform, never block: every OTHER bookshelf this book is on, so a
        -- reader who now has it in two places knows it. Nothing here is a
        -- control — the placement has already happened.
        , viewCompleteExistingShelvesNotice model.existingShelves

        -- Same register, same rule: the book IS shelved. This says why it has
        -- no name on it yet, so the reader is not left to guess.
        , viewProvisionalNoticeIfNeeded book
        , case model.ageGateError of
            Just err ->
                p [ class "upload-complete__age-gate-error", testId "upload-adults-only-error" ]
                    [ text err ]

            Nothing ->
                text ""
        , div [ class "upload-complete__actions" ]
            [ button
                [ class "btn btn--primary"
                , onClick Reset
                ]
                [ text "Add another" ]
            , button
                [ class "btn btn--secondary"
                , onClick (GoToShelf shelfName)
                ]
                [ text "View on shelf" ]
            ]
        ]


{-| Duplicate detected view with merge-format flow.

When a duplicate is found, the user can:

1.  "Yes, merge" — call Api.mergeFormat to add a new edition to the existing book.
2.  "No, add as separate" — proceed to the normal shelf picker as a new placement.
3.  "View Book" — navigate to the existing book detail.

-}
viewDuplicate : Model -> Book -> Html Msg
viewDuplicate model book =
    let
        existingFormat =
            book.primaryEdition
                |> Maybe.andThen .formatLabel
                |> Maybe.withDefault "an edition"
    in
    div [ class "upload-result upload-result--duplicate" ]
        [ h2 [] [ text "Already in Your Library" ]
        , p []
            [ text
                ("You own \""
                    ++ book.title
                    ++ "\" as "
                    ++ existingFormat
                    ++ "."
                )
            ]
        , case model.mergeFormatState of
            Loading ->
                div [ class "upload-duplicate__merge-loading" ]
                    [ span [ class "spinner" ] []
                    , p [] [ text "Merging format..." ]
                    ]

            Failure _ ->
                div [ class "upload-duplicate__merge-error" ]
                    [ p [] [ text "Merge failed. Please try again." ]
                    , viewMergePrompt book
                    ]

            NotAsked ->
                viewMergePrompt book

            -- Unreachable: an accepted merge moves `result` to `EditionMerged`,
            -- and this view only renders for `DuplicateDetected` (#355). Kept
            -- explicit rather than swept into a `_` so that if the transition
            -- is ever removed, this reads as the question it still is.
            Success _ ->
                viewMergePrompt book
        , div [ class "upload-duplicate__secondary" ]
            [ a
                [ href (Route.toPath (Route.BookDetail book.id))
                , class "btn btn--ghost"
                ]
                [ text "View Book" ]
            , button [ class "btn btn--ghost", onClick Reset ] [ text "Go Back" ]
            ]
        ]


viewMergePrompt : Book -> Html Msg
viewMergePrompt book =
    let
        newFormat =
            "a new format"
    in
    div [ class "upload-duplicate__merge" ]
        [ p [] [ text ("Add " ++ newFormat ++ "?") ]
        , div [ class "upload-duplicate__merge-actions" ]
            [ button
                [ class "btn btn--primary"
                , onClick (ConfirmMergeFormat book.id)
                ]
                [ text "Yes, merge" ]
            , button
                [ class "btn btn--secondary"
                , onClick SkipMerge
                ]
                [ text "No, add as separate" ]
            ]
        ]


{-| US-1.1.8, reached from the manual path's 409 (#343).

`Books.confirm/2` matched the ISBN's resolved title+author to a work already in
the catalogue (Jaro-Winkler > 0.8) and refused to create a second one. The
matching is entirely server-side — this screen only consumes the work id it
was handed, and fetches the work purely to name it.

There is deliberately no "no, add it separately": the server has no such
affordance, and offering a button that cannot work is worse than not offering
it. A reader who disagrees with the match can go and look at the work.

-}
viewSameWork : Model -> String -> Maybe Book -> Html Msg
viewSameWork model workId maybeBook =
    div [ class "upload-result upload-result--duplicate", testId "upload-same-work" ]
        [ h2 [] [ text "Already in the Catalogue" ]
        , p [] [ text (sameWorkPrompt maybeBook) ]
        , case model.mergeFormatState of
            Loading ->
                div [ class "upload-duplicate__merge-loading" ]
                    [ span [ class "spinner" ] []
                    , p [] [ text "Merging format..." ]
                    ]

            Failure _ ->
                div [ class "upload-duplicate__merge-error" ]
                    [ p [] [ text "Merge failed. Please try again." ]
                    , viewSameWorkActions workId
                    ]

            NotAsked ->
                viewSameWorkActions workId

            -- Unreachable: see `viewDuplicate`. An accepted merge leaves this
            -- prompt entirely rather than growing a confirmation inside it.
            Success _ ->
                viewSameWorkActions workId
        , div [ class "upload-duplicate__secondary" ]
            [ a
                [ href (Route.toPath (Route.BookDetail workId))
                , class "btn btn--ghost"
                ]
                [ text "View Book" ]
            , button [ class "btn btn--ghost", onClick Reset ] [ text "Go Back" ]
            ]
        ]


viewSameWorkActions : String -> Html Msg
viewSameWorkActions workId =
    div [ class "upload-duplicate__merge" ]
        [ div [ class "upload-duplicate__merge-actions" ]
            [ button
                [ class "btn btn--primary"
                , testId "upload-same-work-merge"
                , onClick (ConfirmMergeFormat workId)
                ]
                [ text "Yes, merge" ]
            ]
        ]


{-| US-1.1.8 copy: "You own [Title] as a [format]. Add the [new format]
edition?" — degraded to a title-free sentence when the work could not be
fetched, which is a cosmetic loss rather than a dead end.
-}
sameWorkPrompt : Maybe Book -> String
sameWorkPrompt maybeBook =
    case maybeBook of
        Just book ->
            "You already have \""
                ++ book.title
                ++ "\" by "
                ++ authorName book
                ++ ". Add this edition to it?"

        Nothing ->
            "We already have this book in the catalogue. Add this edition to it?"


{-| The card an accepted merge lands on — US-1.1.8's completion (#355).

Deliberately the same shape as `viewComplete`: heading, notice, actions, and
`role="status"` so a screen reader is told the screen changed. Both merge
prompts end here, and neither of them is still on screen when it does.

Every sentence is checkable against something the reader can then go and look
at. The ISBN and format are the server's own answer, and "on the book's page"
is only true because the merge now evicts `BookDetailCache` — before that fix,
this card would have named an edition that `View book details` did not show,
which is the same defect in better clothes.

-}
viewEditionMerged : MergedEdition -> Html Msg
viewEditionMerged merged =
    div [ class "upload-complete", testId "upload-merge-complete", attribute "role" "status" ]
        [ h2 [ class "upload-complete__heading" ] [ text (mergedHeading merged.work) ]
        , p [ class "upload-complete__detail" ] [ text (mergedDetail merged.edition) ]
        , viewMergedShelfHint merged.onAReaderShelf
        , div [ class "upload-complete__actions" ]
            [ a
                [ href (Route.toPath (Route.BookDetail merged.workId))
                , class "btn btn--primary"
                ]
                [ text "View book details" ]
            , button [ class "btn btn--secondary", onClick Reset ] [ text "Add another" ]
            ]
        ]


{-| Same naming rule as `completeHeading` — `headingSubject` decides whether the
book has a title worth quoting, so a provisional work is never quoted as if
`Not yet identified` were its name.

`Nothing` is the work whose fetch failed: it is fetched purely so the prompt can
name it, so losing it degrades the sentence rather than stranding the reader.

-}
mergedHeading : Maybe Book -> String
mergedHeading maybeBook =
    case maybeBook of
        Just book ->
            headingSubject book ++ " has a new edition"

        Nothing ->
            "Edition added"


{-| The merged edition, described from the row the server actually wrote.
-}
mergedDetail : Edition -> String
mergedDetail edition =
    case edition.formatLabel of
        Just label ->
            "The " ++ label ++ " edition (ISBN " ++ edition.isbn ++ ") is now listed on the book's page."

        Nothing ->
            "ISBN " ++ edition.isbn ++ " is now listed on the book's page as another edition."


{-| The one thing a merge does NOT do, said only to the reader for whom it is
news. A merge adds an edition to the catalogue; it places nothing on anybody's
bookshelf. The photo path's reader already has the book — that is why they were
offered a merge at all — so telling them would be noise. The manual path's
reader asked to add a book and, so far, has not got one.
-}
viewMergedShelfHint : Bool -> Html Msg
viewMergedShelfHint onAReaderShelf =
    if onAReaderShelf then
        text ""

    else
        p [ class "upload-complete__shelf-hint", testId "upload-merge-shelf-hint" ]
            [ text "It isn't on one of your bookshelves yet — open the book to add it." ]


{-| Map a shelf value to its display label.
-}
shelfLabel : String -> String
shelfLabel shelfValue =
    allShelves
        |> List.filter (\s -> s.value == shelfValue)
        |> List.head
        |> Maybe.map .label
        |> Maybe.withDefault shelfValue


{-| Map a shelf value to its Route.
-}
shelfRoute : String -> Route.Route
shelfRoute shelfName =
    case shelfName of
        "library" ->
            Route.Library

        "antilibrary" ->
            Route.AntiLibrary

        "wishlist" ->
            Route.WishList

        "reading_pile" ->
            Route.ReadingPile

        "looking_for_home" ->
            Route.LookingForHome

        _ ->
            Route.Library
