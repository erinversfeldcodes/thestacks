module Page.BookDetail exposing
    ( Model
    , Msg
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api
import Components.FormatPicker exposing (formatPicker)
import Components.RemoveBookModal exposing (removeBookModal)
import Components.ShelfMover exposing (shelfMover)
import Html exposing (Html, button, div, h1, h2, h3, img, p, section, text)
import Html.Attributes exposing (alt, class, src)
import Html.Events exposing (onClick)
import Http
import Navigation.Route as Route exposing (Route)
import Types.Book exposing (Book)
import Types.Placement exposing (Format, Placement)
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { book : RemoteData Http.Error Book
    , placement : Maybe Placement
    , bookshelfMoverOpen : Bool
    , removeModalOpen : Bool
    , formatPickerOpen : Bool
    , selectedBookshelf : String
    , selectedFormats : List Format
    , removeState : RemoteData Http.Error ()
    , previousRoute : Maybe Route
    }


type OutMsg
    = NoOut
    | NavigateTo Route


type Msg
    = BookLoaded (Result Http.Error Book)
    | OpenBookshelfMover
    | CloseBookshelfMover
    | SelectBookshelf String
    | ConfirmMove
    | MoveCompleted (Result Http.Error ())
    | OpenRemoveModal
    | CloseRemoveModal
    | ConfirmRemove
    | RemoveCompleted (Result Http.Error ())
    | ToggleFormatPicker
    | ToggleFormat Format


init : String -> Maybe String -> Maybe Route -> ( Model, Cmd Msg )
init bookId maybeToken maybePreviousRoute =
    let
        cmd =
            case maybeToken of
                Just token ->
                    Api.getBook bookId token BookLoaded

                Nothing ->
                    Cmd.none
    in
    ( { book = Loading
      , placement = Nothing
      , bookshelfMoverOpen = False
      , removeModalOpen = False
      , formatPickerOpen = False
      , selectedBookshelf = "library"
      , selectedFormats = []
      , removeState = NotAsked
      , previousRoute = maybePreviousRoute
      }
    , cmd
    )


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        BookLoaded result ->
            case result of
                Ok book ->
                    ( { model | book = Success book }, Cmd.none, NoOut )

                Err err ->
                    ( { model | book = Failure err }, Cmd.none, NoOut )

        OpenBookshelfMover ->
            ( { model | bookshelfMoverOpen = True }, Cmd.none, NoOut )

        CloseBookshelfMover ->
            ( { model | bookshelfMoverOpen = False }, Cmd.none, NoOut )

        SelectBookshelf bookshelf ->
            ( { model | selectedBookshelf = bookshelf }, Cmd.none, NoOut )

        ConfirmMove ->
            case ( model.placement, maybeToken ) of
                ( Just placement, Just token ) ->
                    ( { model | bookshelfMoverOpen = False }
                    , Api.moveBook placement.id model.selectedBookshelf token MoveCompleted
                    , NoOut
                    )

                _ ->
                    ( model, Cmd.none, NoOut )

        MoveCompleted _ ->
            ( model, Cmd.none, NoOut )

        OpenRemoveModal ->
            ( { model | removeModalOpen = True }, Cmd.none, NoOut )

        CloseRemoveModal ->
            ( { model | removeModalOpen = False }, Cmd.none, NoOut )

        ConfirmRemove ->
            case ( model.placement, maybeToken ) of
                ( Just placement, Just token ) ->
                    ( { model | removeModalOpen = False, removeState = Loading }
                    , Api.removeBook placement.id token RemoveCompleted
                    , NoOut
                    )

                _ ->
                    ( model, Cmd.none, NoOut )

        RemoveCompleted result ->
            case result of
                Ok _ ->
                    ( { model | removeState = Success () }
                    , Cmd.none
                    , NavigateTo (Maybe.withDefault Route.Library model.previousRoute)
                    )

                Err err ->
                    ( { model | removeState = Failure err }, Cmd.none, NoOut )

        ToggleFormatPicker ->
            ( { model | formatPickerOpen = not model.formatPickerOpen }, Cmd.none, NoOut )

        ToggleFormat format ->
            let
                newFormats =
                    if List.member format model.selectedFormats then
                        List.filter (\f -> f /= format) model.selectedFormats

                    else
                        format :: model.selectedFormats
            in
            ( { model | selectedFormats = newFormats }, Cmd.none, NoOut )


view : Model -> Html Msg
view model =
    div [ class "page page--book-detail" ]
        [ case model.book of
            NotAsked ->
                text ""

            Loading ->
                div [ class "loading" ] [ text "Loading book..." ]

            Failure _ ->
                p [ class "error" ] [ text "Could not load this book. Please try again." ]

            Success book ->
                viewBook model book
        , if model.removeModalOpen then
            case model.book of
                Success book ->
                    removeBookModal
                        { bookTitle = book.title
                        , onConfirm = ConfirmRemove
                        , onCancel = CloseRemoveModal
                        }

                _ ->
                    text ""

          else
            text ""
        ]


viewBook : Model -> Book -> Html Msg
viewBook model book =
    div [ class "book-detail" ]
        [ section [ class "book-detail__hero" ]
            [ div [ class "book-detail__cover" ]
                [ case book.coverImageUrl of
                    Just url ->
                        img
                            [ src url
                            , alt ("Cover of " ++ book.title)
                            , class "book-detail__cover-img"
                            ]
                            []

                    Nothing ->
                        div [ class "book-detail__cover-placeholder" ]
                            [ text "📖" ]
                ]
            , div [ class "book-detail__meta" ]
                [ h1 [ class "book-detail__title" ] [ text book.title ]
                , h2 [ class "book-detail__author" ] [ text book.author.name ]
                , case book.publicationYear of
                    Just year ->
                        p [ class "book-detail__year" ] [ text (String.fromInt year) ]

                    Nothing ->
                        text ""
                , case book.publisher of
                    Just publisher ->
                        p [ class "book-detail__publisher" ] [ text publisher ]

                    Nothing ->
                        text ""
                , case book.pageCount of
                    Just pages ->
                        p [ class "book-detail__pages" ]
                            [ text (String.fromInt pages ++ " pages") ]

                    Nothing ->
                        text ""
                , p [ class "book-detail__isbn" ] [ text ("ISBN: " ++ book.isbn) ]
                ]
            ]
        , section [ class "book-detail__description" ]
            [ case book.description of
                Just desc ->
                    p [] [ text desc ]

                Nothing ->
                    text ""
            ]
        , section [ class "book-detail__author-card" ]
            [ h3 [] [ text "About the Author" ]
            , p [] [ text book.author.name ]
            , case book.author.bio of
                Just bio ->
                    p [] [ text bio ]

                Nothing ->
                    text ""
            ]
        , section [ class "book-detail__shelf-actions" ]
            [ button [ class "btn btn--secondary", onClick OpenBookshelfMover ]
                [ text "Move to Bookshelf" ]
            , if model.bookshelfMoverOpen then
                shelfMover
                    { currentBookshelf = model.selectedBookshelf
                    , selectedBookshelf = model.selectedBookshelf
                    , onSelectBookshelf = SelectBookshelf
                    , onMove = ConfirmMove
                    }

              else
                text ""
            ]
        , section [ class "book-detail__formats" ]
            [ button [ class "btn btn--ghost", onClick ToggleFormatPicker ]
                [ text "Formats" ]
            , if model.formatPickerOpen then
                formatPicker
                    { selected = model.selectedFormats
                    , onToggle = ToggleFormat
                    }

              else
                text ""
            ]
        , section [ class "book-detail__reviews" ]
            [ h3 [] [ text "Reviews" ]
            , p [ class "stub-notice" ] [ text "Reviews coming in Phase 2" ]
            ]
        , section [ class "book-detail__prices" ]
            [ h3 [] [ text "Where to Buy" ]
            , p [ class "stub-notice" ] [ text "Price comparison coming in Phase 2" ]
            ]
        , section [ class "book-detail__danger-zone" ]
            [ button [ class "btn btn--danger", onClick OpenRemoveModal ]
                [ text "Remove from Bookshelf" ]
            ]
        ]
