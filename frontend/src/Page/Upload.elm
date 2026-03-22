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

import Api exposing (BookDetailResponse, PollResponse, PollStatus(..))
import Components.ISBNInput exposing (isValidISBN, isbnInput)
import File exposing (File)
import File.Select as Select
import Html exposing (Html, a, button, div, h1, h2, img, li, option, p, select, span, text, ul)
import Html.Attributes exposing (alt, class, href, src, value)
import Html.Events exposing (onClick, onInput, preventDefaultOn)
import Http
import Json.Decode as Decode
import Navigation.Route as Route
import Process
import Task
import Types.Book exposing (Book, authorName, bookCoverImageUrl)
import Types.Placement exposing (Placement)
import Types.RemoteData exposing (RemoteData(..))


{-| Maximum number of poll attempts before giving up (~300 seconds at 2s intervals).
-}
maxPollCount : Int
maxPollCount =
    150


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

    -- Loading = upload in flight; Success imageId = upload accepted, polling in progress.
    , uploadState : RemoteData Http.Error String
    , pollCount : Int
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
    }


type OutMsg
    = NoOut
    | NavigateTo Route.Route


type Msg
    = GotFile File
    | DragOver
    | DragLeave
    | FilepickerRequested
    | UploadAccepted (Result Http.Error String)
    | CheckStatus
    | StatusReceived (Result Http.Error PollResponse)
    | GotIdentifiedBook String (Result Http.Error BookDetailResponse)
    | GotDuplicateBook (Result Http.Error BookDetailResponse)
    | ManualIsbnChanged String
    | SubmitManualIsbn
    | EnterManualMode
    | DuplicateShelfSelected String
    | ConfirmDuplicateMove String
    | DuplicateMoveCompleted (Result Http.Error ())
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
    , pollCount = 0
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
    }


sleepThenPoll : Cmd Msg
sleepThenPoll =
    Task.perform (\_ -> CheckStatus) (Process.sleep 2000)


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
                        , pollCount = 0
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
                    -- Upload accepted; begin polling for the identification result.
                    ( { model | uploadState = Success imageId }, sleepThenPoll, NoOut )

                Err err ->
                    ( { model | uploadState = Failure err }, Cmd.none, NoOut )

        CheckStatus ->
            case ( model.uploadState, maybeToken ) of
                ( Success imageId, Just token ) ->
                    if model.pollCount >= maxPollCount then
                        -- Timed out waiting for the vision pipeline.
                        ( { model | result = IdentificationFailed }, Cmd.none, NoOut )

                    else
                        ( { model | pollCount = model.pollCount + 1 }
                        , Api.pollUploadStatus imageId token StatusReceived
                        , NoOut
                        )

                _ ->
                    ( model, Cmd.none, NoOut )

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
                                    ( { model | pendingBookIds = [], collectedBooks = [] }
                                    , Api.getBook singleId (Just token) callback
                                    , NoOut
                                    )

                                ( multiIds, Just token ) ->
                                    -- Multiple books: fetch all in parallel.
                                    ( { model
                                        | pendingBookIds = multiIds
                                        , collectedBooks = []
                                      }
                                    , Cmd.batch
                                        (List.map
                                            (\bid -> Api.getBook bid (Just token) (GotIdentifiedBook bid))
                                            multiIds
                                        )
                                    , NoOut
                                    )

                                _ ->
                                    ( { model | result = NotABook }, Cmd.none, NoOut )

                        Rejected ->
                            ( { model | result = IdentificationFailed }, Cmd.none, NoOut )

                        Pending ->
                            ( model, sleepThenPoll, NoOut )

                Err _ ->
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
                    ( { model | result = DuplicateDetected response.book }, Cmd.none, NoOut )

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

        DuplicateShelfSelected shelf ->
            ( { model | duplicateShelf = shelf }, Cmd.none, NoOut )

        ConfirmDuplicateMove _ ->
            -- TODO: Duplicate move requires the existing placement ID, not the book ID.
            -- The merge prompt flow needs a placement lookup step. For now, skip to complete.
            case maybeToken of
                Just _ ->
                    ( { model | duplicateMoveState = Success () }
                    , Cmd.none
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        DuplicateMoveCompleted result ->
            case result of
                Ok _ ->
                    ( { model | duplicateMoveState = Success () }, Cmd.none, NoOut )

                Err err ->
                    ( { model | duplicateMoveState = Failure err }, Cmd.none, NoOut )

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
                        , placementState = Success (placementStub book.id)
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
placementStub : String -> Placement
placementStub _ =
    { id = ""
    , book = Nothing
    , position = Nothing
    , placedAt = Nothing
    , formats = []
    , personalRating = Nothing
    , notes = Nothing
    , bookshelfName = Nothing
    }


view : Model -> Maybe String -> Html Msg
view model maybeToken =
    div [ class "page page--upload" ]
        [ h1 [ class "page__title" ] [ text "Add a Book" ]
        , case maybeToken of
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


viewSignInRequired : Html Msg
viewSignInRequired =
    div [ class "upload-auth-required" ]
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
            , onDrop_
            , onDragOver_
            , onDragLeave_
            ]
            [ case model.uploadState of
                Loading ->
                    div [ class "upload-area__loading" ]
                        [ span [ class "spinner" ] []
                        , p [] [ text "Uploading..." ]
                        ]

                Success _ ->
                    -- Upload accepted; polling the vision pipeline.
                    div [ class "upload-area__loading" ]
                        [ span [ class "spinner" ] []
                        , p [] [ text "Identifying your book..." ]
                        ]

                Failure _ ->
                    div [ class "upload-area__error" ]
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
    div [ class "upload-result upload-result--identified" ]
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
    div [ class "upload-result upload-result--failed" ]
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
    div [ class "upload-result upload-result--not-book" ]
        [ h2 [] [ text "That Doesn't Look Like a Book" ]
        , p []
            [ text
                "We couldn't detect a book in that image. Please try a photo of a book cover."
            ]
        , button [ class "btn btn--primary", onClick Reset ] [ text "Try Again" ]
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
                    , button [ class "btn btn--primary", onClick SubmitManualIsbn ]
                        [ text "Look Up Book" ]
                    ]

            _ ->
                button [ class "btn btn--primary", onClick SubmitManualIsbn ]
                    [ text "Look Up Book" ]
        , button [ class "btn btn--ghost", onClick Reset ] [ text "Cancel" ]
        ]


{-| Verification step: "We think this is..." with confirm/reject.
-}
viewVerifying : Book -> Html Msg
viewVerifying book =
    div [ class "upload-verify" ]
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
                , onClick ConfirmIdentification
                ]
                [ text "Yes, that's it" ]
            , button
                [ class "btn btn--secondary"
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
    div [ class "upload-shelf-picker" ]
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
    div [ class "upload-complete" ]
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


viewDuplicate : Model -> Book -> Html Msg
viewDuplicate model book =
    div [ class "upload-result upload-result--duplicate" ]
        [ h2 [] [ text "Already in Your Library" ]
        , p []
            [ text
                ("\"" ++ book.title ++ "\" is already on one of your shelves.")
            ]
        , a
            [ href (Route.toPath (Route.BookDetail book.id))
            , class "btn btn--primary"
            ]
            [ text "View Book" ]
        , div [ class "upload-duplicate__move" ]
            [ p [] [ text "Move to a different shelf:" ]
            , select
                [ class "upload-duplicate__shelf-select"
                , onInput DuplicateShelfSelected
                ]
                (List.map
                    (\shelf ->
                        option [ value shelf.value ] [ text shelf.label ]
                    )
                    allShelves
                )
            , case model.duplicateMoveState of
                Loading ->
                    p [] [ text "Moving..." ]

                Success _ ->
                    p [ class "upload-duplicate__move-success" ] [ text "Moved!" ]

                Failure _ ->
                    div []
                        [ p [ class "upload-duplicate__move-error" ] [ text "Move failed. Please try again." ]
                        , button
                            [ class "btn btn--secondary"
                            , onClick (ConfirmDuplicateMove book.id)
                            ]
                            [ text "Move to Shelf" ]
                        ]

                NotAsked ->
                    button
                        [ class "btn btn--secondary"
                        , onClick (ConfirmDuplicateMove book.id)
                        ]
                        [ text "Move to Shelf" ]
            ]
        , button [ class "btn btn--ghost", onClick Reset ] [ text "Go Back" ]
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
