module Page.Upload exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , UploadFailure(..)
    , UploadResult(..)
    , UploadStep(..)
    , init
    , sendError
    , tickSeconds
    , update
    , updateWithEffect
    , view
    )

import Api exposing (BookDetailResponse, MergeFormatResponse, PollResponse, PollStatus(..))
import Components.ISBNInput exposing (isValidISBN, isbnInput)
import Effect exposing (Effect)
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


{-| Why a photo did not become a book.

⛔ Every one of these used to be one sentence ("We couldn't read the
ISBN… try a clearer image") covering a downed vision service, a timed-out
stream, a dropped connection, an undecodable image, and a genuine miss —
telling readers to retake photos that were fine. Each cause now carries
its own sentence naming the action actually worth taking.

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
    | SameWorkFound String (Maybe Book)
    | EditionMerged MergedEdition


{-| What the completion card may say, and where each part comes from.
`edition` is the SERVER's answer — the row it actually wrote — so the
card names an ISBN/format that exist. The card this replaces computed
`editionCount + 1` client-side from an earlier fetch: wrong the moment
anyone else merged.
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
    , uploadState : RemoteData Http.Error String
    , result : UploadResult
    , manualIsbn : String
    , showIsbnError : Bool
    , isDragging : Bool
    , duplicateShelf : String
    , duplicateMoveState : RemoteData Http.Error ()
    , pendingBookIds : List String
    , collectedBooks : List Book
    , failedBookIds : List String
    , step : UploadStep
    , selectedShelf : String
    , placementState : RemoteData Api.PlaceError Placement
    , markAdultsOnly : Bool
    , ageGateError : Maybe String
    , ageGatingEnabled : Bool
    , embedded : Bool
    , confirmState : RemoteData Api.ConfirmError ()
    , confirmOutcome : Maybe Api.ConfirmOutcome
    , existingShelves : List String
    , mergeFormatState : RemoteData Http.Error MergeFormatResponse
    , mergeIsbn : String
    , mergeFormatLabel : String
    , sseTerminalReceived : Bool
    , rejectedBookIds : List String
    , waitedSeconds : Int
    , silentSeconds : Int
    }


type OutMsg
    = NoOut
    | NavigateTo Route.Route
    | OpenStream String
    | SessionExpired
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
    , embedded = False
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


{-| The server's `rejection_reason` token as an actionable cause.
Tokens are the union of `VisionError.reason_token/1` and the two the
pipeline writes directly (`isbn_not_found`/`processing_failed`,
`image_too_small`); `not_a_book` is matched one level up as its own
`UploadResult`. Unknown tokens fall to the generic cause — new server
tokens degrade to vaguer copy, never to a wrong specific claim.
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


{-| A transport failure on the upload flow as a cause.

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
the reader the door.

20 seconds is not a guess about the pipeline; it is a guess about patience, and
deliberately so. measured warm vision calls at a median of 5–8s and a p95
of 15–30s, with cold starts reaching 60s — so at 20 seconds the common case has
already answered, and a reader still watching is in the tail this issue exists
to release them from.

-}
leaveAffordanceAfterSeconds : Int
leaveAffordanceAfterSeconds =
    20


{-| After this long with NO frame of any kind, the stream is treated as
silent. The server heartbeats at least every 15s for the stream's whole
life, so this is three missed heartbeats — the watchdog for an
`EventSource` that opens and then emits nothing (previously: a spinner
until the server's own deadline, up to 23 minutes).
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
    let
        ( newModel, effect, out ) =
            updateWithEffect msg model maybeToken
    in
    ( newModel, Effect.perform effect, out )


{-| `update`, with its effect as data.

The program-test harness runs THIS one and interprets the effect, so the
request the page decides to make and the request the tests assert against are
the same value. `update` is this composed with `Effect.perform`; nothing else
differs between them.

-}
updateWithEffect : Msg -> Model -> Maybe String -> ( Model, Effect Msg, OutMsg )
updateWithEffect msg model maybeToken =
    case msg of
        GotFile file ->
            case maybeToken of
                Nothing ->
                    ( { model | file = Just file, isDragging = False }
                    , Effect.none
                    , NoOut
                    )

                Just token ->
                    ( { model
                        | file = Just file
                        , uploadState = Loading
                        , isDragging = False
                        , step = Uploading
                      }
                    , Effect.authed (Api.initUploadRequest (File.mime file))
                        token
                        (Api.resolveJson Api.decodeUploadInit >> UploadInitialised file token)
                    , NoOut
                    )

        UploadInitialised _ _ (Err err) ->
            if Api.isUnauthorized err then
                ( model, Effect.none, SessionExpired )

            else
                ( { model | uploadState = Failure err }, Effect.none, NoOut )

        UploadInitialised file token (Ok init_) ->
            -- A file body cannot be described as an `Api.RequestSpec` (JSON only),
            -- so this one request stays opaque to the simulated runtime.
            ( model
            , Effect.Custom (Api.putFileToR2 init_.uploadUrl file (R2PutCompleted init_.imageId token))
            , NoOut
            )

        R2PutCompleted _ _ (Err err) ->
            ( { model | uploadState = Failure err }, Effect.none, NoOut )

        R2PutCompleted imageId token (Ok ()) ->
            ( model
            , Effect.authed (Api.commitUploadRequest imageId)
                token
                (Api.resolveJson Api.commitUploadDecoder >> UploadAccepted)
            , NoOut
            )

        DragOver ->
            ( { model | isDragging = True }, Effect.none, NoOut )

        DragLeave ->
            ( { model | isDragging = False }, Effect.none, NoOut )

        FilepickerRequested ->
            ( model, Effect.Custom (Select.files [ "image/*" ] (\f _ -> GotFile f)), NoOut )

        UploadAccepted result ->
            case result of
                Ok imageId ->
                    case maybeToken of
                        Just token ->
                            ( { model | uploadState = Success imageId, waitedSeconds = 0, silentSeconds = 0 }
                            , Effect.none
                            , OpenStream ("/api/upload/" ++ imageId ++ "/stream?token=" ++ token)
                            )

                        Nothing ->
                            ( { model | uploadState = Success imageId }, Effect.none, NoOut )

                Err err ->
                    ( { model | uploadState = Failure err }, Effect.none, NoOut )

        StatusReceived result ->
            case result of
                Ok response ->
                    case response.status of
                        Resolved ->
                            case ( resolvedBookIds response, maybeToken ) of
                                ( [], _ ) ->
                                    ( { model | result = NotABook }, Effect.none, NoOut )

                                ( [ _ ], Just token ) ->
                                    ( { model | pendingBookIds = [], collectedBooks = [], failedBookIds = [], sseTerminalReceived = True }
                                    , bookReadEffect token response
                                    , NoOut
                                    )

                                ( multiIds, Just token ) ->
                                    ( { model
                                        | pendingBookIds = multiIds
                                        , collectedBooks = []
                                        , failedBookIds = []
                                        , sseTerminalReceived = True
                                      }
                                    , bookReadEffect token response
                                    , NoOut
                                    )

                                _ ->
                                    ( { model | result = NotABook, sseTerminalReceived = True }, Effect.none, NoOut )

                        Rejected ->
                            case response.rejectionReason of
                                Just "not_a_book" ->
                                    ( terminal model NotABook, Effect.none, NoOut )

                                reason ->
                                    ( terminal model (IdentificationFailed (failureFromRejection reason)), Effect.none, NoOut )

                        TimedOut ->
                            ( terminal model (IdentificationFailed TookTooLong), Effect.none, NoOut )

                        Pending ->
                            ( model, Effect.none, NoOut )

                Err err ->
                    ( { model | result = IdentificationFailed (failureFromHttpError err) }, Effect.none, NoOut )

        StreamEvent rawJson ->
            let
                heard =
                    { model | silentSeconds = 0 }
            in
            case Decode.decodeString Api.streamEventDecoder rawJson of
                Ok pollResponse ->
                    updateWithEffect (StatusReceived (Ok pollResponse)) heard maybeToken

                Err _ ->
                    ( heard, Effect.none, NoOut )

        StreamError ->
            if model.sseTerminalReceived then
                ( model, Effect.none, NoOut )

            else
                ( { model | result = IdentificationFailed ConnectionLost }, Effect.none, NoOut )

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
                        case newCollected of
                            [ singleBook ] ->
                                ( { model
                                    | result = Identified newCollected
                                    , collectedBooks = []
                                    , pendingBookIds = []
                                    , step = Verifying singleBook
                                    , existingShelves =
                                        List.filterMap .bookshelfName response.placements
                                  }
                                , Effect.none
                                , NoOut
                                )

                            _ ->
                                ( { model
                                    | result = Identified newCollected
                                    , collectedBooks = []
                                    , pendingBookIds = []
                                    , existingShelves = []
                                  }
                                , Effect.none
                                , NoOut
                                )

                    else
                        ( { model
                            | collectedBooks = newCollected
                            , pendingBookIds = remaining
                          }
                        , Effect.none
                        , NoOut
                        )

                Err err ->
                    let
                        remaining =
                            List.filter (\bid -> bid /= bookId) model.pendingBookIds

                        newFailed =
                            model.failedBookIds ++ [ bookId ]
                    in
                    if List.isEmpty remaining then
                        case model.collectedBooks of
                            [] ->
                                ( { model | result = IdentificationFailed (failureFromHttpError err), failedBookIds = newFailed }, Effect.none, NoOut )

                            books ->
                                ( { model
                                    | result = Identified books
                                    , collectedBooks = []
                                    , pendingBookIds = []
                                    , failedBookIds = newFailed
                                  }
                                , Effect.none
                                , NoOut
                                )

                    else
                        ( { model | pendingBookIds = remaining, failedBookIds = newFailed }, Effect.none, NoOut )

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
                    , Effect.none
                    , NoOut
                    )

                Err err ->
                    ( { model | result = IdentificationFailed (failureFromHttpError err) }, Effect.none, NoOut )

        ManualIsbnChanged isbn ->
            ( { model | manualIsbn = isbn, showIsbnError = False }, Effect.none, NoOut )

        SubmitManualIsbn ->
            if isValidISBN model.manualIsbn then
                case maybeToken of
                    Just token ->
                        ( { model | confirmState = Loading, existingShelves = [] }
                        , Effect.authed
                            (Api.confirmBookRequest
                                { isbn = model.manualIsbn, shelfName = model.selectedShelf }
                            )
                            token
                            (Api.confirmResponseToResult >> ConfirmCompleted)
                        , NoOut
                        )

                    Nothing ->
                        ( model, Effect.none, NoOut )

            else
                ( { model | showIsbnError = True }, Effect.none, NoOut )

        ConfirmCompleted (Ok response) ->
            ( { model
                | confirmState = Success ()
                , confirmOutcome = Just response.outcome
                , result = Identified [ response.book ]
                , step = Complete response.book model.selectedShelf
                , existingShelves = otherShelves model.selectedShelf response.placements
              }
            , Effect.none
            , RefreshInbox
            )

        ConfirmCompleted (Err (Api.ConfirmMergeRequired workId)) ->
            ( { model
                | confirmState = NotAsked
                , result = SameWorkFound workId Nothing
                , mergeIsbn = model.manualIsbn
                , mergeFormatState = NotAsked
              }
            , case maybeToken of
                Just token ->
                    Effect.authed (Api.getBookRequest workId)
                        token
                        (Api.resolveJson Api.bookDetailResponseDecoder >> GotSameWorkBook)

                Nothing ->
                    Effect.none
            , NoOut
            )

        ConfirmCompleted (Err (Api.ConfirmHttpError err)) ->
            if Api.isUnauthorized err then
                ( model, Effect.none, SessionExpired )

            else
                ( { model | confirmState = Failure (Api.ConfirmHttpError err) }, Effect.none, NoOut )

        ConfirmCompleted (Err confirmError) ->
            ( { model | confirmState = Failure confirmError }, Effect.none, NoOut )

        GotSameWorkBook result ->
            case ( result, model.result ) of
                ( Ok response, SameWorkFound workId _ ) ->
                    ( { model | result = SameWorkFound workId (Just response.book) }
                    , Effect.none
                    , NoOut
                    )

                _ ->
                    ( model, Effect.none, NoOut )

        EnterManualMode ->
            ( { model | result = ManualISBNEntry, confirmState = NotAsked }, Effect.none, NoOut )

        ConfirmMergeFormat bookId ->
            case maybeToken of
                Just token ->
                    ( { model | mergeFormatState = Loading }
                    , Effect.authed
                        (Api.mergeFormatRequest bookId
                            { isbn = model.mergeIsbn, formatLabel = model.mergeFormatLabel }
                        )
                        token
                        (Api.resolveJson Api.mergeFormatResponseDecoder >> MergeFormatCompleted)
                    , NoOut
                    )

                Nothing ->
                    ( model, Effect.none, NoOut )

        SkipMerge ->
            case model.result of
                DuplicateDetected book ->
                    ( { model
                        | result = Identified [ book ]
                        , step = Verifying book
                      }
                    , Effect.none
                    , NoOut
                    )

                _ ->
                    ( model, Effect.none, NoOut )

        MergeFormatCompleted result ->
            case result of
                Ok response ->
                    ( { model
                        | mergeFormatState = Success response
                        , result = mergeCompletionFor response.edition model.result
                      }
                    , Effect.none
                    , NoOut
                    )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Effect.none, SessionExpired )

                    else
                        ( { model | mergeFormatState = Failure err }, Effect.none, NoOut )

        Reset ->
            ( init, Effect.none, NoOut )

        ConfirmIdentification ->
            case model.step of
                Verifying book ->
                    ( { model | step = ChoosingShelf book }, Effect.none, NoOut )

                _ ->
                    ( model, Effect.none, NoOut )

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
                    , Effect.authed
                        (Api.rejectIdentificationRequest
                            { imageId = imageId, rejectedBookIds = newRejected }
                        )
                        token
                        (Api.resolveWhatever >> RejectIdentificationCompleted)
                    , OpenStream ("/api/upload/" ++ imageId ++ "/stream?token=" ++ token)
                    )

                _ ->
                    ( init, Effect.none, NoOut )

        RejectIdentificationCompleted result ->
            case result of
                Ok () ->
                    ( model, Effect.none, NoOut )

                Err err ->
                    ( { model | result = IdentificationFailed (failureFromHttpError err) }, Effect.none, NoOut )

        ShelfSelected shelf ->
            ( { model | selectedShelf = shelf }, Effect.none, NoOut )

        ToggleAdultsOnly ->
            ( { model | markAdultsOnly = not model.markAdultsOnly }, Effect.none, NoOut )

        ConfirmPlacement ->
            case ( model.step, maybeToken ) of
                ( ChoosingShelf book, Just token ) ->
                    let
                        ageGateEffect =
                            if model.ageGatingEnabled && model.markAdultsOnly then
                                [ Effect.authed (Api.setBookAgeGateRequest book.id)
                                    token
                                    (Api.resolveWhatever >> AgeGateSet)
                                ]

                            else
                                []
                    in
                    ( { model | placementState = Loading, ageGateError = Nothing }
                    , Effect.batch
                        (Effect.authed (Api.placeBookRequest model.selectedShelf book.id)
                            token
                            (Api.placeResponseToResult >> PlacementCompleted)
                            :: ageGateEffect
                        )
                    , NoOut
                    )

                _ ->
                    ( model, Effect.none, NoOut )

        AgeGateSet result ->
            case result of
                Ok () ->
                    ( model, Effect.none, NoOut )

                Err _ ->
                    ( { model | ageGateError = Just "We couldn't mark this book as adults only. You can change it later from the book's page." }
                    , Effect.none
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
                    , Effect.none
                    , RefreshInbox
                    )

                ( Err Api.PlaceReadingPileFull, _ ) ->
                    ( { model | placementState = Failure Api.PlaceReadingPileFull }, Effect.none, NoOut )

                ( Err (Api.PlaceHttpError err), _ ) ->
                    if Api.isUnauthorized err then
                        ( model, Effect.none, SessionExpired )

                    else
                        ( { model | placementState = Failure (Api.PlaceHttpError err) }, Effect.none, NoOut )

                _ ->
                    ( model, Effect.none, NoOut )

        GoToShelf shelfName ->
            ( model, Effect.none, NavigateTo (shelfRoute shelfName) )

        WaitTick ->
            if isWaiting model then
                ( { model
                    | waitedSeconds = model.waitedSeconds + tickSeconds
                    , silentSeconds = model.silentSeconds + tickSeconds
                  }
                , Effect.none
                , NoOut
                )

            else
                ( { model | waitedSeconds = 0, silentSeconds = 0 }, Effect.none, NoOut )

        ResumeInboxItem item ->
            updateWithEffect
                (StatusReceived (Ok (replayFrame item)))
                { init
                    | ageGatingEnabled = model.ageGatingEnabled
                    , uploadState = Success item.imageId
                }
                maybeToken


{-| The books a resolved status frame is about.

The stream reports one book in `book_id` and several in `book_ids`; a frame
carrying the singular form alone still means one identified book.

-}
resolvedBookIds : PollResponse -> List String
resolvedBookIds response =
    if List.isEmpty response.bookIds then
        case response.bookId of
            Just bid ->
                [ bid ]

            Nothing ->
                []

    else
        response.bookIds


{-| Which book-read each identified book gets, and what its answer means: the
same photo resolving to a book the reader already owns is a duplicate to
reconcile, not a new arrival to place.

The page reads this to build its requests and a program test reads it to build
its simulated ones, so the two cannot disagree about which of the two callbacks
a duplicate produces.

-}
resolvedBookReads : PollResponse -> List ( String, Result Http.Error BookDetailResponse -> Msg )
resolvedBookReads response =
    case resolvedBookIds response of
        [ singleId ] ->
            [ ( singleId
              , if response.isDuplicate then
                    GotDuplicateBook

                else
                    GotIdentifiedBook singleId
              )
            ]

        ids ->
            List.map (\bid -> ( bid, GotIdentifiedBook bid )) ids


bookReadEffect : String -> PollResponse -> Effect Msg
bookReadEffect token response =
    Effect.batch
        (List.map
            (\( bookId, toMsg ) ->
                Effect.authed (Api.getBookRequest bookId)
                    token
                    (Api.resolveJson Api.bookDetailResponseDecoder >> toMsg)
            )
            (resolvedBookReads response)
        )


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
        , if model.embedded then
            text ""

          else
            div [ class "upload-import-link" ]
                [ a
                    [ class "btn btn--ghost"
                    , href (Route.toPath Route.Import)
                    , testId "upload-import-link"
                    ]
                    [ text "Coming from Goodreads? Import your whole library" ]
                ]
        ]


{-| The waiting screen, which stops promising imminence. The old
eternal `Processing image...` spinner implied seconds for up to 35
measured minutes, and only a reader who stayed ever saw the result.
This tells the truth — identification continues in the background — and
says where the answer will be waiting (the inbox), making leaving safe.
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


{-| The inbox: uploads this reader started and has not finished with. Identification is asynchronous, so this is how work done in the
reader's absence is reached again; confirmation is synchronous, so every
item is a LINK into the existing confirm flow and nothing more — no
"add all", no control here that shelves a book.
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


{-| A failed inbox item's summary, through the SAME tables as the live
path (`failureFromRejection` token→cause, `failureBody` cause→sentence).
A second table would drift the day a token was added, telling two
stories about one rejection. `not_a_book` is mapped explicitly here
because the inbox has no live-path interception to do it.
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


{-| Why the photo never reached the library at all.

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


{-| The failure card, saying WHICH failure it is. Both affordances
(retry, manual entry) stay on every cause; the sentence changes and
names the button worth reaching for.

⛔ Copy must only name controls that exist — `Page.Bookshelf.loadError`
once shipped "then try again" onto a page with no retry control.

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
            "The image itself could not be read — it may be damaged, or too large, or in a format we cannot open. A photo taken afresh usually works; so does typing the ISBN in."

        IsbnUnreadable ->
            "We found a book but could not make out its ISBN. A closer photo of the barcode or the copyright page will usually do it — or type the number in."

        ServiceUnavailable ->
            "The service that reads book covers is not answering. There is nothing wrong with your photo. Type the ISBN in to add the book now, or try the photo again later."

        TookTooLong ->
            "Your photo was accepted, but no verdict ever came back for it. Nothing has been added to your shelves. Try the photo again, or type the ISBN in."

        ConnectionLost ->
            "We lost the connection before hearing how your photo went. Check your connection, then try again."

        CauseUnknown ->
            "Your photo did not become a book, and we cannot say why. It may be nothing to do with the photo. Try again in a moment, or type the ISBN in."


{-| The one sentence for `not_a_book`, shared by the card and the inbox summary. Named rather than duplicated so the two surfaces cannot come to disagree
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


{-| Manual ISBN entry, now a single screen and a single request.

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
The barcode fast path skips the OL/GB round-trip, so a book can be
shelved before anything knows its title; until enrichment lands the
server's stand-in title is the ISBN itself. This predicate (via
`Types.Book.isProvisional`) is how surfaces render that as a pending
lookup instead of a book named after a number.
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
age-gated AND age-gating is enabled. Per the upload
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
notice.

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


{-| The same notice on the completion card. The manual path learns the
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


{-| The screen a merge lands on, given the prompt it was answered from.

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

Asks `isUnidentified`, not `isProvisional`: "does this book have a name"
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
        , viewExistingShelvesNotice model.existingShelves
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
picker (photo path) and the manual-entry screen so the two ways of
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
already sitting there is the same class of untruth as the pre-silent
second placement — the reader must be able to tell what actually happened.
`Nothing` is the photo path, which places directly and always added.

-}
viewComplete : Model -> Book -> String -> Html Msg
viewComplete model book shelfName =
    div [ class "upload-complete", testId "upload-complete", attribute "role" "status" ]
        [ h2 [ class "upload-complete__heading" ]
            [ text (completeHeading model.confirmOutcome book shelfName) ]
        , viewCompleteExistingShelvesNotice model.existingShelves
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


{-| , reached from the manual path's 409.

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


{-| copy: "You own [Title] as a [format]. Add the [new format]
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


{-| The card an accepted merge lands on — completion.

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
