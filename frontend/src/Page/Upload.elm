module Page.Upload exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , UploadFailure(..)
    , UploadResult(..)
    , UploadStep(..)
    , init
    , replayFrame
    , sendError
    , tickSeconds
    , update
    , view
    )

import Api exposing (BookDetailResponse, MergeFormatResponse, PollResponse, PollStatus(..))
import Components.ISBNInput exposing (isValidISBN, isbnInput)
import File exposing (File)
import File.Select as Select
import Html exposing (Html, a, button, div, h1, h2, img, input, label, li, p, span, text, ul)
import Html.Attributes exposing (alt, attribute, checked, class, disabled, href, src, type_)
import Html.Events exposing (onCheck, onClick, preventDefaultOn)
import Http
import Json.Decode as Decode
import Navigation.Route as Route
import Types.Book exposing (Book, Edition, VisibilityTier(..), authorName, bookCoverImageUrl, bookIsbn, displayTitle, isUnidentified)
import Types.Placement exposing (Placement)
import Types.RemoteData exposing (RemoteData(..))
import Util.FailureCopy as FailureCopy
import Util.TestId exposing (testId)


{-| Why a photo did not become a book (Issue #374).

⛔ **Every one of these used to be the same sentence.** `IdentificationFailed`
was a nullary constructor rendering "We couldn't read the ISBN from this photo.
Try a clearer image or enter the ISBN manually." — and `Page.Upload` routed
_everything_ into it: a vision service that was down, an SSE stream that timed
out, a connection that dropped, an image the service could not decode at all,
and a genuine could-not-read-the-ISBN. Four of those five had nothing to do with
the photo's clarity, so the advice was wrong four times out of five, and the
reader's move — retake the photo, more carefully — could not possibly work.

The information was there the whole time. `Stacks.Uploads.reject_image/2` writes
a `rejection_reason` token, `IdentifyBookJob` chooses it from
`Stacks.AI.VisionError.reason_token/1`, and the SSE frame carries it in
`rejection_reason`. This page received it and discarded it.

`CauseUnknown` is not a gap in this list — it is a member of it. A token this
client has never seen (the server grew one after we shipped) must produce a
message that says so, because the alternative is the defect above wearing a
smaller hat.

  - `ImageUnreadable` — `undecodable_image`, `image_too_large`,
    `image_too_small`, `image_unreachable`, `no_image_supplied`,
    `malformed_request`. The service looked at the bytes and could not use them.
    Nothing to do with whether a book is in shot.
  - `IsbnUnreadable` — `isbn_not_found`. A book was found, its ISBN was not. The
    one cause the old message actually described.
  - `ServiceUnavailable` — `vision_unavailable`, `vision_budget_exceeded`. The
    identification service never answered. The photo is fine.
  - `TookTooLong` — the SSE stream's own `"timeout"` frame: the pipeline's
    deadline passed with no verdict. Distinct from every rejection, because no
    determination was ever made.
  - `ConnectionLost` — the stream errored, or a request on this flow failed at
    the transport. The reader's connection, not the library's opinion of their
    photo.
  - `CauseUnknown` — a token we do not recognise, a status we do not handle, a
    rejection with no reason attached.

-}
type UploadFailure
    = ImageUnreadable
    | IsbnUnreadable
    | ServiceUnavailable
    | TookTooLong
    | ConnectionLost
    | CauseUnknown


type UploadResult
    = NoResult
    | Identified (List Book)
    | IdentificationFailed UploadFailure
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

    -- How long this reader has been watching a spinner, and how long the SSE
    -- stream has been silent, both in seconds and both advanced by `WaitTick`
    -- (Issue #351).
    --
    -- ⛔ These are the ONLY two numbers the waiting copy is allowed to speak
    -- from, because they are the only two the client actually knows. There is
    -- no attempt counter on the wire — the row stays `pending` across retries,
    -- so no frame is broadcast between them — and "retrying now" or "attempt 2
    -- of 3" invented here would be reassurance with nothing behind it.
    --
    -- `silentSeconds` is reset by ANY stream frame, heartbeats included: a
    -- heartbeat fails `streamEventDecoder` on purpose and is ignored as a
    -- status, but its arrival is still proof the stream is alive. That is what
    -- makes it a watchdog rather than a second timeout.
    , waitedSeconds : Int
    , silentSeconds : Int
    }


type OutMsg
    = NoOut
    | NavigateTo Route.Route
    | OpenStream String
    | SessionExpired
      -- Something happened that changes what is waiting for this reader — a
      -- book was placed, or added by hand. The inbox and its navigation badge
      -- live in `Main`, so this asks for a refetch rather than mutating a copy
      -- (Issue #351). One list, one owner, no second count to drift.
    | RefreshInbox


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
    | WaitTick
    | ResumeInboxItem Api.InboxItem


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
    , waitedSeconds = 0
    , silentSeconds = 0
    }


{-| The server's `rejection_reason` token as a cause the reader can act on
(Issue #374).

The tokens are the union of `Stacks.AI.VisionError.reason_token/1` and the two
the pipeline writes directly (`Stacks.Workers.IdentifyBookJob`'s `not_a_book` /
`isbn_not_found` / `processing_failed` and `Stacks.Uploads.commit_image/2`'s
`image_too_small`). `not_a_book` never reaches here — it is matched one level up,
where it becomes its own `UploadResult`.

⛔ **The catch-all must stay `CauseUnknown`.** It covers three things that look
different and are the same: a token added server-side after this client shipped,
`processing_failed` (which is itself the server saying it does not know), and a
`Rejected` frame with no reason at all. Mapping any of them onto a specific
cause would be inventing one — and this function is exactly where that invention
would be cheap and invisible.

-}
failureFromRejection : Maybe String -> UploadFailure
failureFromRejection reason =
    case reason of
        Just "undecodable_image" ->
            ImageUnreadable

        Just "image_too_large" ->
            ImageUnreadable

        Just "image_too_small" ->
            ImageUnreadable

        Just "image_unreachable" ->
            ImageUnreadable

        Just "no_image_supplied" ->
            ImageUnreadable

        Just "malformed_request" ->
            ImageUnreadable

        Just "isbn_not_found" ->
            IsbnUnreadable

        Just "vision_unavailable" ->
            ServiceUnavailable

        Just "vision_budget_exceeded" ->
            ServiceUnavailable

        _ ->
            CauseUnknown


{-| A transport failure on the upload flow as a cause (Issue #374).

Only the two `Http.Error` constructors that describe themselves get their own
cause. A `BadStatus` is a number, and a number is not a reason a reader can act
on — 500, 502 and 503 all mean "not now, and not because of you", which is what
`CauseUnknown` says.

-}
failureFromHttpError : Http.Error -> UploadFailure
failureFromHttpError err =
    case err of
        Http.Timeout ->
            TookTooLong

        Http.NetworkError ->
            ConnectionLost

        _ ->
            CauseUnknown


{-| How many seconds one `WaitTick` stands for.

`Main` drives the tick, so this constant and that subscription's interval are
one fact in two places; a 1000ms subscription against a 5 here would make the
page claim a minute had passed after twelve seconds. Both are named, and the
thresholds below are coarse enough (20s, 45s) that the pairing is checkable by
reading rather than by stopwatch.

-}
tickSeconds : Int
tickSeconds =
    5


{-| After this long, the page stops implying the answer is imminent and offers
the reader the door (Issue #351).

20 seconds is not a guess about the pipeline; it is a guess about patience, and
deliberately so. #349 measured warm vision calls at a median of 5–8s and a p95
of 15–30s, with cold starts reaching 60s — so at 20 seconds the common case has
already answered, and a reader still watching is in the tail this issue exists
to release them from.

-}
leaveAffordanceAfterSeconds : Int
leaveAffordanceAfterSeconds =
    20


{-| After this long with NO frame of any kind, the stream is treated as silent.

`UploadController.sse_receive_loop/4` chunks a heartbeat at least every 15
seconds for the whole life of the stream, so three missed heartbeats is the
threshold. This is the watchdog #374 left for this issue: an `EventSource` that
opens and then emits neither message nor error used to leave the spinner
turning until the server's own deadline — up to 23 minutes — with the client
having no way to tell a working slow pipeline from a dead socket.

⛔ Crossing it does **not** produce a failure. The job is very probably still
running, and #342's derivation exists precisely because declaring a timeout
while work is in flight is a lie. What it produces is an honest statement about
the connection, and a pointer at the inbox — which is where the answer will
land whether this socket recovers or not.

-}
streamSilentAfterSeconds : Int
streamSilentAfterSeconds =
    45


{-| Is this page waiting on an identification right now?

`Success imageId` means the upload was accepted and a stream was opened;
`NoResult` with `step == Uploading` means nothing has come back yet. Anything
else — a result, a verify step, a shelf picker — is the reader's turn, and the
clocks must not run during it.

-}
isWaiting : Model -> Bool
isWaiting model =
    case ( model.uploadState, model.result, model.step ) of
        ( Success _, NoResult, Uploading ) ->
            True

        _ ->
            False


{-| The SSE frame an inbox item would have arrived as, had the reader stayed.

This is the whole of the inbox's "resume" logic, and it is a data conversion
rather than a flow: every screen it can lead to already exists, reached by the
function the live stream reaches it by.

-}
replayFrame : Api.InboxItem -> PollResponse
replayFrame item =
    { imageId = item.imageId
    , status =
        case item.kind of
            Api.AwaitingConfirmation ->
                Resolved

            Api.Failed ->
                Rejected
    , bookId = List.head item.bookIds
    , bookIds = item.bookIds
    , rejectionReason = item.rejectionReason
    , isDuplicate = False
    }


{-| Settle on a terminal result and clear the in-flight bookkeeping with it.

Four call sites were writing the same six-field update by hand, and the fields
are not optional: leaving `pendingBookIds` populated behind a terminal result
lets a late `GotIdentifiedBook` overwrite the message the reader is reading.

-}
terminal : Model -> UploadResult -> Model
terminal model result =
    { model
        | result = result
        , pendingBookIds = []
        , collectedBooks = []
        , failedBookIds = []
        , sseTerminalReceived = True
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
                -- ⛔ This used to store `Failure Http.NetworkError` and throw
                -- `err` away — so a 429 from the `:upload` rate-limit bucket, a
                -- 413, and a genuinely dropped connection were all recorded as
                -- the same thing. The view could not have told them apart if it
                -- wanted to: the distinction was destroyed one layer earlier
                -- (Issue #374).
                ( { model | uploadState = Failure err }, Cmd.none, NoOut )

        UploadInitialised file token (Ok init_) ->
            ( model
            , Api.putFileToR2 init_.uploadUrl file (R2PutCompleted init_.imageId token)
            , NoOut
            )

        R2PutCompleted _ _ (Err err) ->
            -- The bytes going to R2 directly, so this is the one failure that
            -- really is usually the connection — but it is not always, and the
            -- error already says which.
            ( { model | uploadState = Failure err }, Cmd.none, NoOut )

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
                    -- The two clocks start here and not at `GotFile`: the wait
                    -- this page is honest about is the wait for identification,
                    -- not the seconds spent sending the bytes.
                    case maybeToken of
                        Just token ->
                            ( { model | uploadState = Success imageId, waitedSeconds = 0, silentSeconds = 0 }
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
                                    ( terminal model NotABook, Cmd.none, NoOut )

                                reason ->
                                    ( terminal model (IdentificationFailed (failureFromRejection reason)), Cmd.none, NoOut )

                        TimedOut ->
                            -- The stream's deadline is derived from the job's own
                            -- worst-case lifetime, so reaching it means no verdict
                            -- is still coming — not that one arrived and was bad.
                            ( terminal model (IdentificationFailed TookTooLong), Cmd.none, NoOut )

                        Pending ->
                            ( model, Cmd.none, NoOut )

                Err err ->
                    ( { model | result = IdentificationFailed (failureFromHttpError err) }, Cmd.none, NoOut )

        StreamEvent rawJson ->
            -- ⛔ The reset happens for EVERY frame, before the decode is even
            -- attempted. A heartbeat is not a status — it deliberately fails
            -- `streamEventDecoder` — but it is proof the stream is alive, and
            -- that proof is the whole content of the watchdog. Moving this
            -- reset inside the `Ok` branch would leave `silentSeconds` climbing
            -- through a perfectly healthy stream and declare a working
            -- connection dead 45 seconds in.
            let
                heard =
                    { model | silentSeconds = 0 }
            in
            case Decode.decodeString Api.streamEventDecoder rawJson of
                Ok pollResponse ->
                    update (StatusReceived (Ok pollResponse)) heard maybeToken

                Err _ ->
                    -- Malformed event (e.g. heartbeat) — ignore, stay in current state.
                    ( heard, Cmd.none, NoOut )

        StreamError ->
            -- Ignore the error if we already received a terminal SSE event.
            -- When the server closes the connection immediately after sending
            -- resolved/rejected, the browser fires onerror right after the
            -- message — before book fetches complete. The flag prevents that
            -- connection-close error from overwriting the correct pipeline state.
            if model.sseTerminalReceived then
                ( model, Cmd.none, NoOut )

            else
                -- An `EventSource` error before any terminal frame. The browser
                -- reports these without a status, so the honest reading is "the
                -- stream broke" — never "your photo was unreadable", which is
                -- what this branch used to say.
                ( { model | result = IdentificationFailed ConnectionLost }, Cmd.none, NoOut )

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

                Err err ->
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
                                -- The pipeline DID identify books; fetching them
                                -- failed. Nothing was learned about the photo, so
                                -- the failure is the fetch's, not the photo's.
                                ( { model | result = IdentificationFailed (failureFromHttpError err), failedBookIds = newFailed }, Cmd.none, NoOut )

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

                Err err ->
                    -- The duplicate's own record would not load. The photo was
                    -- identified; this is a fetch failure downstream of that.
                    ( { model | result = IdentificationFailed (failureFromHttpError err) }, Cmd.none, NoOut )

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
              -- Adding by hand is exactly the "the reader got the book another
              -- way" case the inbox predicate has to notice — a photo of this
              -- same book may be sitting in it, and is now finished business.
            , RefreshInbox
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

                Err err ->
                    -- The server didn't accept the "that's not my book" request.
                    -- Surface the failure on the same screen the reader would see
                    -- on a pipeline failure rather than wedging in the spinner —
                    -- but as the transport failure it is, not as a verdict on a
                    -- photo the pipeline was never re-asked about.
                    ( { model | result = IdentificationFailed (failureFromHttpError err) }, Cmd.none, NoOut )

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
                      -- The book is now on a bookshelf, so whatever upload
                      -- produced it has stopped awaiting attention. Ask for the
                      -- inbox again rather than decrementing a local number: the
                      -- server owns the predicate, and a client that subtracts
                      -- one is a second implementation of it.
                    , RefreshInbox
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

        WaitTick ->
            if isWaiting model then
                ( { model
                    | waitedSeconds = model.waitedSeconds + tickSeconds
                    , silentSeconds = model.silentSeconds + tickSeconds
                  }
                , Cmd.none
                , NoOut
                )

            else
                -- Not waiting on anything. Zeroing rather than freezing means a
                -- second upload in the same session starts from nothing said
                -- rather than inheriting the last one's elapsed time.
                ( { model | waitedSeconds = 0, silentSeconds = 0 }, Cmd.none, NoOut )

        ResumeInboxItem item ->
            -- ⛔ The inbox does NOT have a confirm flow. It has an entrance to
            -- the one that already exists.
            --
            -- Everything below rebuilds the SSE frame the reader would have
            -- received had they stayed on the page, and hands it to
            -- `StatusReceived` — the same function the live stream calls. From
            -- there the reader is in `Verifying`, then `ChoosingShelf`, then
            -- `ConfirmPlacement`, with "No, try again" and its cumulative
            -- exclusion list intact (which is why `uploadState` must be
            -- `Success item.imageId`: `RejectIdentification` reads the image id
            -- from there). A second implementation is what #343 had to delete.
            --
            -- `isDuplicate = False` is not a guess. The server drops candidates
            -- the reader has already shelved before the item is ever listed, so
            -- an item that reached this client has, by construction, nothing on
            -- a shelf to be a duplicate of. If the reader shelved it in another
            -- tab in the meantime, `GotIdentifiedBook` still reads the book's
            -- real placements and shows the "already yours" notice (#333) —
            -- informing, never blocking.
            update
                (StatusReceived (Ok (replayFrame item)))
                { init
                    | ageGatingEnabled = model.ageGatingEnabled
                    , uploadState = Success item.imageId
                }
                maybeToken


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


view : Model -> Maybe String -> RemoteData Http.Error (List Api.InboxItem) -> Html Msg
view model maybeToken inbox =
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

                                IdentificationFailed cause ->
                                    viewIdentificationFailed cause

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

        -- The inbox lives on the upload page and nowhere else (owner ruling,
        -- #351) — this is the page a reader comes to when they want to add a
        -- book, so it is the page where unfinished attempts belong. It renders
        -- outside the aria-live region on purpose: it is standing content, not
        -- an announcement, and having a screen reader read the whole list out
        -- every time the upload status changed would be the opposite of help.
        , case maybeToken of
            Nothing ->
                text ""

            Just _ ->
                viewInbox model inbox
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
                        , p [] [ text "Sending your photo..." ]
                        ]

                Success _ ->
                    viewWaiting model

                Failure err ->
                    div
                        [ class "upload-area__error"
                        , testId "upload-error"
                        , attribute "data-failure-cause" "not-sent"
                        ]
                        [ p [] [ text (sendError err) ]
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
        , div [ class "upload-import-link" ]
            [ a
                [ class "btn btn--ghost"
                , href (Route.toPath Route.Import)
                , testId "upload-import-link"
                ]
                [ text "Coming from Goodreads? Import your whole library" ]
            ]
        ]


{-| The waiting screen, which stops promising imminence (Issue #351).

This screen used to be a spinner and the words `Processing image...`, forever,
and that was the hostage-taking: it implied the answer was seconds away for as
long as 35 minutes (#350's measured worst case), and a reader who believed it
and stayed was the only reader who ever saw the result. Leaving lost the work
entirely — the job finished, the row went `resolved`, and no surface could
reach it again until the 30-day sweep deleted it.

Three things are said here and nothing else is:

  - what is happening, in the present tense and without a deadline;
  - after `leaveAffordanceAfterSeconds`, that the reader may leave, and where
    the answer will be when they come back. This is the sentence the issue is
    for. It is offered on elapsed time because elapsed time is a fact the
    client owns;
  - after `streamSilentAfterSeconds`, that this page has stopped hearing from
    the server — the watchdog.

⛔ What is NOT said: any claim about retries. `IdentifyBookJob` may be on its
second or third attempt, and the reader would no doubt like to know, but the
row stays `pending` across attempts so **no frame is broadcast between them**
and this client cannot tell. "Retrying..." here would be a sentence with
nothing behind it, and reassurance that is not backed by knowledge is the thing
this whole issue is replacing.

-}
viewWaiting : Model -> Html Msg
viewWaiting model =
    div [ class "upload-area__loading", testId "upload-loading", attribute "role" "status" ]
        [ span [ class "spinner" ] []
        , p [] [ text "Reading your photo..." ]
        , if model.silentSeconds >= streamSilentAfterSeconds then
            p
                [ class "upload-waiting__stream-silent"
                , testId "upload-stream-silent"
                ]
                [ text "This page has stopped hearing back from the library. Identification is still running — the result will be waiting for you under Add a Book whenever you return." ]

          else if model.waitedSeconds >= leaveAffordanceAfterSeconds then
            p
                [ class "upload-waiting__leave-note"
                , testId "upload-leave-note"
                ]
                [ text "This one is taking a while. You don't have to wait — you can close this page and carry on. We'll keep going, and the result will be waiting for you under Add a Book." ]

          else
            text ""
        ]


{-| The inbox: uploads this reader started and has not finished with (#351).

The owner's ruling in two halves. Identification is asynchronous, so this list
is how work done in the reader's absence is reached again. Confirmation is
synchronous, so **every item here is a link into the existing confirm flow and
nothing more** — there is no "add all", no "accept", no control on this surface
that puts a book on a bookshelf. Selecting an item shows the reader what we
think their photo was and asks.

Failures sit in the same list with different copy and no confirmation to make,
because a rejection the reader never saw is lost work too. They are visibly a
different kind of thing, and they are not counted on the navigation badge —
`Api.awaitingConfirmationCount` is the only definition of that number.

⚠️ An item stays here until it is finished or until the 30-day image-retention
sweep deletes the row underneath it. For an awaiting-confirmation item that is
right: it disappears the moment the book reaches a bookshelf by any route. For
a failure there is no such moment — nothing the reader can do marks it read,
because dismissal would need a write route and #351 is scoped to a read-only
one. It is therefore a list that can accumulate stale failures for up to a
month. Recorded rather than hidden; see the report.

-}
viewInbox : Model -> RemoteData Http.Error (List Api.InboxItem) -> Html Msg
viewInbox model inbox =
    case inbox of
        Success [] ->
            text ""

        Success items ->
            div [ class "upload-inbox", testId "upload-inbox" ]
                [ h2 [ class "upload-inbox__heading" ] [ text "Waiting for you" ]
                , p [ class "upload-inbox__intro" ]
                    [ text "Photos you sent earlier that we finished without you." ]
                , ul [ class "upload-inbox__list" ] (List.map (viewInboxItem model) items)
                ]

        Failure _ ->
            -- Silence here would be the worse failure: a reader with three
            -- books waiting would be shown an empty page and told nothing.
            -- Note that the navigation badge renders nothing in this state, and
            -- that is correct — it cannot count a list it does not have.
            p [ class "upload-inbox__error", testId "upload-inbox-error" ]
                [ text "We couldn't check whether anything is waiting for you. Reload the page to try again." ]

        _ ->
            text ""


viewInboxItem : Model -> Api.InboxItem -> Html Msg
viewInboxItem model item =
    let
        ( itemClass, copy, action ) =
            case item.kind of
                Api.AwaitingConfirmation ->
                    ( "upload-inbox__item"
                    , "We found a book in this photo. Have a look and tell us if we got it right."
                    , "Check this one"
                    )

                Api.Failed ->
                    ( "upload-inbox__item upload-inbox__item--failed"
                    , inboxFailureSummary item
                    , "See what happened"
                    )
    in
    li
        [ class itemClass
        , testId "upload-inbox-item"
        , attribute "data-inbox-kind" (inboxKindToken item.kind)
        ]
        [ p [ class "upload-inbox__item-text" ] [ text copy ]
        , button
            [ class "btn btn--secondary"
            , testId "upload-inbox-resume"
            , onClick (ResumeInboxItem item)

            -- Selecting an item replaces whatever is on the upload surface
            -- above, so it is disabled once the reader is mid-flow rather than
            -- silently throwing away a half-finished confirmation.
            , disabled (not (canResume model))
            ]
            [ text action ]
        ]


{-| Whether picking up an inbox item now would destroy work in progress.

The reader is free to resume from the drop prompt or from a finished result;
they are not free to do it from the middle of a verify or shelf-picker step,
where the click would silently discard the book they were in the act of filing.

-}
canResume : Model -> Bool
canResume model =
    case model.step of
        Uploading ->
            not (isWaiting model)

        _ ->
            False


{-| A failed inbox item's summary, through the SAME tables the live path uses.

`failureFromRejection` is the one mapping from a server token to a cause, and
`failureBody` the one mapping from a cause to a sentence. A second table here
would drift the day a token was added — and the reader would then be told two
different stories about one rejection depending on whether they happened to be
looking at the time.

`not_a_book` is the one token the live path handles a level up, where it becomes
its own screen rather than one of the six causes. It gets that screen's own
sentence here rather than a seventh `UploadFailure` constructor: #374's six are
the causes the failure CARD distinguishes, and widening that type to serve a
list summary would have made every one of its case expressions answer a
question it was not asked.

-}
inboxFailureSummary : Api.InboxItem -> String
inboxFailureSummary item =
    case item.rejectionReason of
        Just "not_a_book" ->
            notABookBody

        reason ->
            failureBody (failureFromRejection reason)


inboxKindToken : Api.InboxKind -> String
inboxKindToken kind =
    case kind of
        Api.AwaitingConfirmation ->
            "awaiting-confirmation"

        Api.Failed ->
            "failed"


{-| Why the photo never reached the library at all (Issue #374).

This is the failure BEFORE identification: the presign, the R2 PUT or the commit
did not go through. It read "Upload failed. Please try again." for every one of
them, including a 429 — where trying again immediately is precisely the thing
that will fail — and a 413, where trying the same file again cannot ever work.

The 429 arrives here as a bare `Http.BadStatus 429`: these endpoints are
authenticated and go through `Api.authedExpect`, which has already discarded the
headers by the time a caller sees the error, so `retry-after` is unavailable and
the copy names no interval. See `Api.RequestError` for why that is a deliberate
silence rather than a gap.

-}
sendError : Http.Error -> String
sendError err =
    case err of
        Http.BadStatus 413 ->
            "That photo is too large to send. A smaller one — or your phone's own resized copy — will go through."

        Http.BadStatus 415 ->
            "That file is not an image we can read. A JPEG or PNG photo of the cover will work."

        Http.BadStatus 429 ->
            FailureCopy.rateLimited Nothing

        Http.BadStatus 503 ->
            "The library is briefly overloaded. Please try again in a few seconds."

        Http.NetworkError ->
            "The library is unreachable, so your photo was never sent. Check your connection, then try again."

        Http.Timeout ->
            "Sending your photo took too long and we stopped waiting. A stronger connection, or a smaller photo, usually gets it there."

        _ ->
            -- Same rule as `CauseUnknown`: no status number is a reason, and
            -- guessing one at the reader is how "Upload failed" got here.
            "Your photo could not be sent, and we cannot say why. Please try again in a moment."


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


{-| The failure card, saying which failure it is (Issue #374).

Both affordances stay on every cause, because both remain genuinely available
and a reader who wants the other one should not have to guess. What changes is
the sentence, and the sentence names the button worth reaching for.

⛔ That last part is not decoration. `Page.Bookshelf`'s `loadError` shipped a
message ending "then try again" onto a page with no retry control anywhere
(#368) — copy the reader cannot act on is a second failure stacked on the first.
Every string below ends on something the two buttons underneath it can actually
do, and `ConnectionLost` is the one that does **not** say "type the ISBN in",
because manual entry needs the same connection that just failed.

⛔ **The test id stays `upload-error` for every cause, and the cause rides
alongside it in `data-failure-cause`.** Nine Playwright assertions use
`getByTestId("upload-error")` as the "did the pipeline fail" sentinel — several
of them as an escape hatch that fails the test fast rather than hanging for five
minutes. Splitting the id per cause would have left each of those watching for
one particular failure and timing out silently on the other five, which is the
same defect this issue is about, moved into the test suite.

The class stays `upload-result--failed` too: these are one card with six things
to say, not six cards.

-}
viewIdentificationFailed : UploadFailure -> Html Msg
viewIdentificationFailed cause =
    div
        [ class "upload-result upload-result--failed"
        , testId "upload-error"
        , attribute "data-failure-cause" (failureCause cause)
        ]
        [ h2 [] [ text (failureHeading cause) ]
        , p [] [ text (failureBody cause) ]
        , button [ class "btn btn--primary", onClick Reset ] [ text "Try Another Photo" ]
        , button [ class "btn btn--secondary", onClick EnterManualMode ]
            [ text "Enter ISBN Manually" ]
        ]


{-| The cause as a stable machine-readable token, for tests and for a live drive.

Deliberately not the server's own `rejection_reason`: several tokens map to one
cause, and a card is identified by what it SAYS, not by which of the synonyms
produced it.

-}
failureCause : UploadFailure -> String
failureCause cause =
    case cause of
        ImageUnreadable ->
            "image-unreadable"

        IsbnUnreadable ->
            "isbn-unreadable"

        ServiceUnavailable ->
            "service-unavailable"

        TookTooLong ->
            "timed-out"

        ConnectionLost ->
            "connection-lost"

        CauseUnknown ->
            "unknown"


failureHeading : UploadFailure -> String
failureHeading cause =
    case cause of
        ImageUnreadable ->
            "That Photo Could Not Be Opened"

        IsbnUnreadable ->
            "Could Not Read the ISBN"

        ServiceUnavailable ->
            "The Cataloguing Desk Is Closed"

        TookTooLong ->
            "No Answer Came Back"

        ConnectionLost ->
            "The Library Is Unreachable"

        CauseUnknown ->
            "Something Went Wrong"


failureBody : UploadFailure -> String
failureBody cause =
    case cause of
        ImageUnreadable ->
            -- The service rejected the FILE, not its contents, so "try a clearer
            -- image" would be advice about the wrong thing entirely.
            "The image itself could not be read — it may be damaged, or too large, or in a format we cannot open. A photo taken afresh usually works; so does typing the ISBN in."

        IsbnUnreadable ->
            "We found a book but could not make out its ISBN. A closer photo of the barcode or the copyright page will usually do it — or type the number in."

        ServiceUnavailable ->
            -- Naming the photo as blameless is the point: without it a reader
            -- retakes a perfectly good picture against a service that is down.
            "The service that reads book covers is not answering. There is nothing wrong with your photo. Type the ISBN in to add the book now, or try the photo again later."

        TookTooLong ->
            "Your photo was accepted, but no verdict ever came back for it. Nothing has been added to your shelves. Try the photo again, or type the ISBN in."

        ConnectionLost ->
            "We lost the connection before hearing how your photo went. Check your connection, then try again."

        CauseUnknown ->
            -- ⛔ The whole reason this constructor exists. Every other branch
            -- above is a claim; this one refuses to make one, and says why it is
            -- refusing, so the reader does not go looking for a mistake in a
            -- photo that may be perfectly good.
            "Your photo did not become a book, and we cannot say why. It may be nothing to do with the photo. Try again in a moment, or type the ISBN in."


{-| The one sentence for `not_a_book`, shared by the card and the inbox summary
(#351). Named rather than duplicated so the two surfaces cannot come to disagree
about what happened to the same photo.
-}
notABookBody : String
notABookBody =
    "We couldn't detect a book in that image. Please try a photo of a book cover."


viewNotABook : Html Msg
viewNotABook =
    div
        [ class "upload-result upload-result--not-book"
        , testId "upload-error"
        , attribute "data-failure-cause" "not-a-book"
        ]
        [ h2 [] [ text "That Doesn't Look Like a Book" ]
        , p [] [ text notABookBody ]
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

Keyed off `isUnidentified`, not `isProvisional` (#370): the sentence promises a
title will "fill in shortly", so it may only be shown where none is shown yet.
The same predicate drives `displayTitle` above it, so the card cannot print a
name and then say it is waiting for one.

-}
viewProvisionalNoticeIfNeeded : Book -> Html Msg
viewProvisionalNoticeIfNeeded book =
    if isUnidentified book then
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
book has one. An unidentified book does not — quoting `Not yet identified` would
present a status as if it were the title, which is the same untruth as quoting
the ISBN. `this book` is what a person would say.

Asks `isUnidentified`, not `isProvisional` (#370): "does this book have a name"
is exactly the question a quoted heading needs answered, and whether a provider
confirmed its ISBN is not that question.

-}
headingSubject : Book -> String
headingSubject book =
    if isUnidentified book then
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
