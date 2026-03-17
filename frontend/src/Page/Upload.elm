module Page.Upload exposing
    ( Model
    , Msg(..)
    , UploadResult(..)
    , init
    , update
    , view
    )

import Api exposing (PollResponse, PollStatus(..))
import Components.ISBNInput exposing (isValidISBN, isbnInput)
import File exposing (File)
import File.Select as Select
import Html exposing (Html, a, button, div, h1, h2, li, option, p, select, span, text, ul)
import Html.Attributes exposing (class, href, value)
import Html.Events exposing (onClick, onInput, preventDefaultOn)
import Http
import Json.Decode as Decode
import Navigation.Route as Route
import Process
import Task
import Types.Book exposing (Book, authorName)
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
    }


type Msg
    = GotFile File
    | DragOver
    | DragLeave
    | FilepickerRequested
    | UploadAccepted (Result Http.Error String)
    | CheckStatus
    | StatusReceived (Result Http.Error PollResponse)
    | GotIdentifiedBook String (Result Http.Error Book)
    | GotDuplicateBook (Result Http.Error Book)
    | ManualIsbnChanged String
    | SubmitManualIsbn
    | EnterManualMode
    | DuplicateShelfSelected String
    | ConfirmDuplicateMove String
    | DuplicateMoveCompleted (Result Http.Error ())
    | Reset


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
    }


sleepThenPoll : Cmd Msg
sleepThenPoll =
    Task.perform (\_ -> CheckStatus) (Process.sleep 2000)


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg )
update msg model maybeToken =
    case msg of
        GotFile file ->
            case maybeToken of
                Nothing ->
                    -- Not authenticated — send to login rather than silently hanging.
                    ( { model | file = Just file, isDragging = False }
                    , Cmd.none
                    )

                Just token ->
                    ( { model
                        | file = Just file
                        , uploadState = Loading
                        , pollCount = 0
                        , isDragging = False
                      }
                    , Api.uploadImage file token UploadAccepted
                    )

        DragOver ->
            ( { model | isDragging = True }, Cmd.none )

        DragLeave ->
            ( { model | isDragging = False }, Cmd.none )

        FilepickerRequested ->
            ( model, Select.files [ "image/*" ] (\f _ -> GotFile f) )

        UploadAccepted result ->
            case result of
                Ok imageId ->
                    -- Upload accepted; begin polling for the identification result.
                    ( { model | uploadState = Success imageId }, sleepThenPoll )

                Err err ->
                    ( { model | uploadState = Failure err }, Cmd.none )

        CheckStatus ->
            case ( model.uploadState, maybeToken ) of
                ( Success imageId, Just token ) ->
                    if model.pollCount >= maxPollCount then
                        -- Timed out waiting for the vision pipeline.
                        ( { model | result = IdentificationFailed }, Cmd.none )

                    else
                        ( { model | pollCount = model.pollCount + 1 }
                        , Api.pollUploadStatus imageId token StatusReceived
                        )

                _ ->
                    ( model, Cmd.none )

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
                                    ( { model | result = NotABook }, Cmd.none )

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
                                    , Api.getBook singleId token callback
                                    )

                                ( multiIds, Just token ) ->
                                    -- Multiple books: fetch all in parallel.
                                    ( { model
                                        | pendingBookIds = multiIds
                                        , collectedBooks = []
                                      }
                                    , Cmd.batch
                                        (List.map
                                            (\bid -> Api.getBook bid token (GotIdentifiedBook bid))
                                            multiIds
                                        )
                                    )

                                _ ->
                                    ( { model | result = NotABook }, Cmd.none )

                        Rejected ->
                            ( { model | result = IdentificationFailed }, Cmd.none )

                        Pending ->
                            ( model, sleepThenPoll )

                Err _ ->
                    ( { model | result = IdentificationFailed }, Cmd.none )

        GotIdentifiedBook bookId result ->
            case result of
                Ok book ->
                    let
                        newCollected =
                            model.collectedBooks ++ [ book ]

                        remaining =
                            List.filter (\bid -> bid /= bookId) model.pendingBookIds
                    in
                    if List.isEmpty remaining then
                        -- All books fetched — show the result.
                        ( { model
                            | result = Identified newCollected
                            , collectedBooks = []
                            , pendingBookIds = []
                          }
                        , Cmd.none
                        )

                    else
                        ( { model
                            | collectedBooks = newCollected
                            , pendingBookIds = remaining
                          }
                        , Cmd.none
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
                                ( { model | result = IdentificationFailed }, Cmd.none )

                            books ->
                                ( { model
                                    | result = Identified books
                                    , collectedBooks = []
                                    , pendingBookIds = []
                                  }
                                , Cmd.none
                                )

                    else
                        ( { model | pendingBookIds = remaining }, Cmd.none )

        GotDuplicateBook result ->
            case result of
                Ok book ->
                    ( { model | result = DuplicateDetected book }, Cmd.none )

                Err _ ->
                    ( { model | result = IdentificationFailed }, Cmd.none )

        ManualIsbnChanged isbn ->
            ( { model | manualIsbn = isbn, showIsbnError = False }, Cmd.none )

        SubmitManualIsbn ->
            if isValidISBN model.manualIsbn then
                ( { model | result = ManualISBNEntry }, Cmd.none )

            else
                ( { model | showIsbnError = True }, Cmd.none )

        EnterManualMode ->
            ( { model | result = ManualISBNEntry }, Cmd.none )

        DuplicateShelfSelected shelf ->
            ( { model | duplicateShelf = shelf }, Cmd.none )

        ConfirmDuplicateMove bookId ->
            case maybeToken of
                Just token ->
                    ( { model | duplicateMoveState = Loading }
                    , Api.moveBook bookId model.duplicateShelf token DuplicateMoveCompleted
                    )

                Nothing ->
                    ( model, Cmd.none )

        DuplicateMoveCompleted result ->
            case result of
                Ok _ ->
                    ( { model | duplicateMoveState = Success () }, Cmd.none )

                Err err ->
                    ( { model | duplicateMoveState = Failure err }, Cmd.none )

        Reset ->
            ( init, Cmd.none )


view : Model -> Maybe String -> Html Msg
view model maybeToken =
    div [ class "page page--upload" ]
        [ h1 [ class "page__title" ] [ text "Add a Book" ]
        , case maybeToken of
            Nothing ->
                viewSignInRequired

            Just _ ->
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
        , button [ class "btn btn--primary", onClick SubmitManualIsbn ]
            [ text "Look Up Book" ]
        , button [ class "btn btn--ghost", onClick Reset ] [ text "Cancel" ]
        ]


allShelves : List { value : String, label : String }
allShelves =
    [ { value = "library", label = "Library" }
    , { value = "antilibrary", label = "Antilibrary" }
    , { value = "wishlist", label = "Wish List" }
    , { value = "reading_pile", label = "Reading Pile" }
    , { value = "looking_for_home", label = "Looking for a Home" }
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
