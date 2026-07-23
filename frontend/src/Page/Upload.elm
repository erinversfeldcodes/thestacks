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
import Types.Book exposing (Book, VisibilityTier(..), authorName, bookCoverImageUrl)
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

    -- ISBN lookup state
    , isbnLookupState : RemoteData Http.Error ()

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
    | IsbnLookupResult (Result Http.Error BookDetailResponse)
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
    , isbnLookupState = NotAsked
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
                                            if response.isDuplicate == Just True then
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
                                  }
                                , Cmd.none
                                , NoOut
                                )

                            _ ->
                                ( { model
                                    | result = Identified newCollected
                                    , collectedBooks = []
                                    , pendingBookIds = []
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

        SubmitManualIsbn ->
            if isValidISBN model.manualIsbn then
                case maybeToken of
                    Just token ->
                        ( { model | isbnLookupState = Loading }
                        , Api.lookupByIsbn model.manualIsbn token IsbnLookupResult
                        , NoOut
                        )

                    Nothing ->
                        ( model, Cmd.none, NoOut )

            else
                ( { model | showIsbnError = True }, Cmd.none, NoOut )

        IsbnLookupResult result ->
            case result of
                Ok response ->
                    ( { model
                        | isbnLookupState = Success ()
                        , result = Identified [ response.book ]
                        , step = Verifying response.book
                      }
                    , Cmd.none
                    , NoOut
                    )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | isbnLookupState = Failure err }, Cmd.none, NoOut )

        EnterManualMode ->
            ( { model | result = ManualISBNEntry, isbnLookupState = NotAsked }, Cmd.none, NoOut )

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
                    case model.result of
                        DuplicateDetected book ->
                            let
                                newEditionCount =
                                    book.editionCount + 1
                            in
                            ( { model
                                | mergeFormatState = Success response
                                , result =
                                    DuplicateDetected
                                        { book | editionCount = newEditionCount }
                              }
                            , Cmd.none
                            , NoOut
                            )

                        _ ->
                            ( { model | mergeFormatState = Success response }
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
                            viewVerifying model.ageGatingEnabled book

                        ChoosingShelf book ->
                            viewChoosingShelf model book

                        Complete book shelfName ->
                            viewComplete model.ageGateError book shelfName

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
        [ p [ class "upload-result__book-title" ] [ text book.title ]
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


viewManualEntry : Model -> Html Msg
viewManualEntry model =
    div [ class "upload-result upload-result--manual" ]
        [ h2 [] [ text "Enter ISBN Manually" ]
        , isbnInput
            { value = model.manualIsbn
            , onInput = ManualIsbnChanged
            , showError = model.showIsbnError
            }
        , case model.isbnLookupState of
            Loading ->
                div [ class "upload-manual__loading" ]
                    [ span [ class "spinner" ] []
                    , p [] [ text "Looking up book..." ]
                    ]

            Failure _ ->
                div [ class "upload-manual__error" ]
                    [ p [ class "upload-manual__error-text" ]
                        [ text "Book not found. Please check the ISBN and try again." ]
                    , button [ class "btn btn--primary", testId "upload-manual-isbn-submit", onClick SubmitManualIsbn ]
                        [ text "Look Up Book" ]
                    ]

            _ ->
                button [ class "btn btn--primary", testId "upload-manual-isbn-submit", onClick SubmitManualIsbn ]
                    [ text "Look Up Book" ]
        , button [ class "btn btn--ghost", onClick Reset ] [ text "Cancel" ]
        ]


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


{-| Verification step: "We think this is..." with confirm/reject.
-}
viewVerifying : Bool -> Book -> Html Msg
viewVerifying ageGatingEnabled book =
    div [ class "upload-verify", testId "upload-verify" ]
        [ h2 [ class "upload-verify__heading" ] [ text "We think this is…" ]
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
                    [ p [ class "upload-verify__title" ] [ text book.title ]
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
            [ text ("Add \"" ++ book.title ++ "\" to a shelf") ]
        , div [ class "upload-shelf-picker__shelves" ]
            (List.map
                (\shelf ->
                    button
                        [ class
                            (if shelf.value == model.selectedShelf then
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
-}
viewComplete : Maybe String -> Book -> String -> Html Msg
viewComplete ageGateError book shelfName =
    div [ class "upload-complete", testId "upload-complete", attribute "role" "status" ]
        [ h2 [ class "upload-complete__heading" ]
            [ text
                ("\""
                    ++ book.title
                    ++ "\" added to "
                    ++ shelfLabel shelfName
                )
            ]
        , case ageGateError of
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
            Success _ ->
                viewMergeSuccess book

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


viewMergeSuccess : Book -> Html Msg
viewMergeSuccess book =
    div [ class "upload-duplicate__merge-success" ]
        [ p [ class "upload-duplicate__merge-success-text" ]
            [ text
                ("\""
                    ++ book.title
                    ++ "\" now has "
                    ++ String.fromInt book.editionCount
                    ++ " edition"
                    ++ (if book.editionCount == 1 then
                            ""

                        else
                            "s"
                       )
                )
            ]
        , a
            [ href (Route.toPath (Route.BookDetail book.id))
            , class "btn btn--primary"
            ]
            [ text "View book details" ]
        , button [ class "btn btn--secondary", onClick Reset ] [ text "Add another" ]
        ]


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
