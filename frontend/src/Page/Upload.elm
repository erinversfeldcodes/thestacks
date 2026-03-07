module Page.Upload exposing
    ( Model
    , Msg
    , UploadResult(..)
    , init
    , update
    , view
    )

import Api exposing (UploadResponse)
import Components.ISBNInput exposing (isValidISBN, isbnInput)
import File exposing (File)
import File.Select as Select
import Html exposing (Html, a, button, div, h1, h2, option, p, select, span, text)
import Html.Attributes exposing (class, href, value)
import Html.Events exposing (onClick, onInput, preventDefaultOn)
import Http
import Json.Decode as Decode
import Navigation.Route as Route
import Types.Book exposing (Book)
import Types.RemoteData exposing (RemoteData(..))


type UploadResult
    = NoResult
    | Identified Book
    | IdentificationFailed
    | NotABook
    | ManualISBNEntry
    | DuplicateDetected Book


type alias Model =
    { file : Maybe File
    , uploadState : RemoteData Http.Error UploadResponse
    , result : UploadResult
    , manualIsbn : String
    , showIsbnError : Bool
    , isDragging : Bool
    , duplicateShelf : String
    , duplicateMoveState : RemoteData Http.Error ()
    }


type Msg
    = GotFiles File (List File)
    | DragOver
    | DragLeave
    | RequestFilePicker
    | UploadCompleted (Result Http.Error UploadResponse)
    | GotIdentifiedBook (Result Http.Error Book)
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
    , result = NoResult
    , manualIsbn = ""
    , showIsbnError = False
    , isDragging = False
    , duplicateShelf = "library"
    , duplicateMoveState = NotAsked
    }


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg )
update msg model maybeToken =
    case msg of
        GotFiles file _ ->
            let
                cmd =
                    case maybeToken of
                        Just token ->
                            Api.uploadImage file token UploadCompleted

                        Nothing ->
                            Cmd.none
            in
            ( { model
                | file = Just file
                , uploadState = Loading
                , isDragging = False
              }
            , cmd
            )

        DragOver ->
            ( { model | isDragging = True }, Cmd.none )

        DragLeave ->
            ( { model | isDragging = False }, Cmd.none )

        RequestFilePicker ->
            ( model, Select.files [ "image/*" ] GotFiles )

        UploadCompleted result ->
            case result of
                Ok response ->
                    case response.status of
                        "identified" ->
                            case ( response.bookId, maybeToken ) of
                                ( Just bookId, Just token ) ->
                                    ( { model | uploadState = Success response }
                                    , Api.getBook bookId token GotIdentifiedBook
                                    )

                                _ ->
                                    ( { model
                                        | uploadState = Success response
                                        , result = IdentificationFailed
                                      }
                                    , Cmd.none
                                    )

                        "not_a_book" ->
                            ( { model
                                | uploadState = Success response
                                , result = NotABook
                              }
                            , Cmd.none
                            )

                        "duplicate" ->
                            case ( response.bookId, maybeToken ) of
                                ( Just bookId, Just token ) ->
                                    ( { model | uploadState = Success response }
                                    , Api.getBook bookId token GotDuplicateBook
                                    )

                                _ ->
                                    ( { model
                                        | uploadState = Success response
                                        , result = IdentificationFailed
                                      }
                                    , Cmd.none
                                    )

                        _ ->
                            ( { model
                                | uploadState = Success response
                                , result = IdentificationFailed
                              }
                            , Cmd.none
                            )

                Err err ->
                    ( { model | uploadState = Failure err }, Cmd.none )

        GotIdentifiedBook result ->
            case result of
                Ok book ->
                    ( { model | result = Identified book }, Cmd.none )

                Err _ ->
                    ( { model | result = IdentificationFailed }, Cmd.none )

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


view : Model -> Html Msg
view model =
    div [ class "page page--upload" ]
        [ h1 [ class "page__title" ] [ text "Add a Book" ]
        , case model.result of
            NoResult ->
                viewUploadArea model

            Identified book ->
                viewIdentified book

            IdentificationFailed ->
                viewIdentificationFailed

            NotABook ->
                viewNotABook

            ManualISBNEntry ->
                viewManualEntry model

            DuplicateDetected book ->
                viewDuplicate model book
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
                (Decode.map2 GotFiles
                    (Decode.index 0 File.decoder)
                    (Decode.succeed [])
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

                Success _ ->
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
            , onClick RequestFilePicker
            ]
            [ text "Choose Photo" ]
        ]


viewIdentified : Book -> Html Msg
viewIdentified book =
    div [ class "upload-result upload-result--identified" ]
        [ h2 [] [ text "Book Identified!" ]
        , p [] [ text book.title ]
        , p [] [ text book.author.name ]
        , a
            [ href (Route.toPath (Route.BookDetail book.id))
            , class "btn btn--primary"
            ]
            [ text "View Book" ]
        , button [ class "btn btn--ghost", onClick Reset ] [ text "Try Another" ]
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
