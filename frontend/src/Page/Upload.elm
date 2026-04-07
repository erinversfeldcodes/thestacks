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
import Html exposing (Html, a, button, div, h1, h2, img, li, p, span, text, ul)
import Html.Attributes exposing (alt, attribute, class, href, src)
import Html.Events exposing (onClick, preventDefaultOn)
import Http
import Json.Decode as Decode
import Navigation.Route as Route
import Types.Book exposing (Book, authorName, bookCoverImageUrl)
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

    -- Verification step state machine
    , step : UploadStep
    , selectedShelf : String
    , placementState : RemoteData Http.Error Placement

    -- ISBN lookup state
    , isbnLookupState : RemoteData Http.Error ()

    -- Merge format flow
    , mergeFormatState : RemoteData Http.Error MergeFormatResponse
    , mergeIsbn : String
    , mergeFormatLabel : String

    -- True once a terminal SSE event (resolved/rejected) has been received.
    -- Used to suppress spurious StreamError after the server closes the connection.
    , sseTerminalReceived : Bool
    }


type OutMsg
    = NoOut
    | NavigateTo Route.Route
    | OpenStream String


type Msg
    = GotFile File
    | DragOver
    | DragLeave
    | FilepickerRequested
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
    | ShelfSelected String
    | ConfirmPlacement
    | PlacementCompleted (Result Http.Error Placement)
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
    , step = Uploading
    , selectedShelf = "wishlist"
    , placementState = NotAsked
    , isbnLookupState = NotAsked
    , mergeFormatState = NotAsked
    , mergeIsbn = ""
    , mergeFormatLabel = ""
    , sseTerminalReceived = False
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
                    ( { model
                        | file = Just file
                        , uploadState = Loading
                        , isDragging = False
                        , step = Uploading
                      }
                    , Api.uploadImage file token UploadAccepted
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
                                    ( { model | pendingBookIds = [], collectedBooks = [], sseTerminalReceived = True }
                                    , Api.getBook singleId (Just token) callback
                                    , NoOut
                                    )

                                ( multiIds, Just token ) ->
                                    -- Multiple books: fetch all in parallel.
                                    ( { model
                                        | pendingBookIds = multiIds
                                        , collectedBooks = []
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
                                    ( { model | result = NotABook, sseTerminalReceived = True }, Cmd.none, NoOut )

                                _ ->
                                    ( { model | result = IdentificationFailed, sseTerminalReceived = True }, Cmd.none, NoOut )

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
                    -- One book fetch failed — remove from pending; show what we have
                    -- if everything else is done, otherwise keep waiting.
                    let
                        remaining =
                            List.filter (\bid -> bid /= bookId) model.pendingBookIds
                    in
                    if List.isEmpty remaining then
                        case model.collectedBooks of
                            [] ->
                                ( { model | result = IdentificationFailed }, Cmd.none, NoOut )

                            books ->
                                ( { model
                                    | result = Identified books
                                    , collectedBooks = []
                                    , pendingBookIds = []
                                  }
                                , Cmd.none
                                , NoOut
                                )

                    else
                        ( { model | pendingBookIds = remaining }, Cmd.none, NoOut )

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
            ( init, Cmd.none, NoOut )

        ShelfSelected shelf ->
            ( { model | selectedShelf = shelf }, Cmd.none, NoOut )

        ConfirmPlacement ->
            case ( model.step, maybeToken ) of
                ( ChoosingShelf book, Just token ) ->
                    ( { model | placementState = Loading }
                    , Api.placeBook model.selectedShelf book.id token PlacementCompleted
                    , NoOut
                    )

                _ ->
                    ( model, Cmd.none, NoOut )

        PlacementCompleted result ->
            case ( result, model.step ) of
                ( Ok _, ChoosingShelf book ) ->
                    ( { model
                        | step = Complete book model.selectedShelf
                        , placementState = Success placementStub
                      }
                    , Cmd.none
                    , NoOut
                    )

                ( Err err, _ ) ->
                    ( { model | placementState = Failure err }, Cmd.none, NoOut )

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
                            viewVerifying book

                        ChoosingShelf book ->
                            viewChoosingShelf model book

                        Complete book shelfName ->
                            viewComplete book shelfName

                        Uploading ->
                            case model.result of
                                NoResult ->
                                    viewUploadArea model

                                Identified books ->
                                    viewIdentified books

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


viewIdentified : List Book -> Html Msg
viewIdentified books =
    div [ class "upload-result upload-result--identified", attribute "role" "status", testId "upload-identified" ]
        ([ h2 []
            [ text
                (if List.length books == 1 then
                    "Book Identified!"

                 else
                    "Books Identified!"
                )
            ]
         , ul [ class "upload-result__book-list" ]
            (List.map viewIdentifiedBook books)
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


{-| Verification step: "We think this is..." with confirm/reject.
-}
viewVerifying : Book -> Html Msg
viewVerifying book =
    div [ class "upload-verify", testId "upload-verify" ]
        [ h2 [ class "upload-verify__heading" ] [ text "We think this is…" ]
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
        , case model.placementState of
            Loading ->
                div [ class "upload-shelf-picker__loading" ]
                    [ span [ class "spinner" ] []
                    , p [] [ text "Adding to shelf..." ]
                    ]

            Failure _ ->
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


{-| Success step: book placed on shelf.
-}
viewComplete : Book -> String -> Html Msg
viewComplete book shelfName =
    div [ class "upload-complete", testId "upload-complete", attribute "role" "status" ]
        [ h2 [ class "upload-complete__heading" ]
            [ text
                ("\""
                    ++ book.title
                    ++ "\" added to "
                    ++ shelfLabel shelfName
                )
            ]
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
