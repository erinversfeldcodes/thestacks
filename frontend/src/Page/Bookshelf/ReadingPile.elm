module Page.Bookshelf.ReadingPile exposing
    ( Model
    , Msg
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api
import Components.AgeGate exposing (ageGate)
import Components.Spine exposing (WearLevel(..))
import Html exposing (Html, button, div, p, text)
import Html.Attributes exposing (attribute, class, style)
import Html.Events exposing (onClick, onMouseEnter, stopPropagationOn)
import Http
import Json.Decode as Decode
import Navigation.Route exposing (Route(..))
import Page.Bookshelf.Helpers exposing (pickTexture)
import Types.Book exposing (Book, bookCoverImageUrl, bookPageCount)
import Types.Placement exposing (Placement)
import Types.RemoteData exposing (RemoteData(..))
import Types.Shelf exposing (Shelf)
import Util.TestId exposing (testId)


type alias Model =
    { books : RemoteData Http.Error (List Placement)
    , showAgeGate : Bool
    , selectedBookId : Maybe String
    }


type OutMsg
    = NoOut
    | NavigateTo Route
    | SessionExpired


type Msg
    = BooksLoaded (Result Http.Error (List Shelf))
    | VerifyAge
    | DismissAgeGate
    | BookHovered String
    | BookClicked Book
    | Deselect


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    let
        cmd =
            case maybeToken of
                Just token ->
                    Api.getBookshelf "reading_pile" token BooksLoaded

                Nothing ->
                    Cmd.none
    in
    ( { books = Loading, showAgeGate = False, selectedBookId = Nothing }, cmd )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        BooksLoaded result ->
            case result of
                Ok shelves ->
                    ( { model | books = Success (List.concatMap .placements shelves) }, Cmd.none, NoOut )

                Err (Http.BadStatus 403) ->
                    ( { model | books = Failure (Http.BadStatus 403), showAgeGate = True }, Cmd.none, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | books = Failure err }, Cmd.none, NoOut )

        VerifyAge ->
            ( model, Cmd.none, NavigateTo SettingsAgeVerification )

        DismissAgeGate ->
            ( { model | showAgeGate = False }, Cmd.none, NoOut )

        BookHovered bookId ->
            ( { model | selectedBookId = Just bookId }, Cmd.none, NoOut )

        BookClicked bk ->
            if model.selectedBookId == Just bk.id then
                ( model, Cmd.none, NavigateTo (BookDetail bk.id) )

            else
                ( { model | selectedBookId = Just bk.id }, Cmd.none, NoOut )

        Deselect ->
            ( { model | selectedBookId = Nothing }, Cmd.none, NoOut )


view : Model -> Html Msg
view model =
    div
        [ class "page page--shelf shelf-reading-pile"
        , testId "reading-pile-page"
        , onClick Deselect
        ]
        [ div [ class "wallpaper wallpaper--dragons" ] []
        , div [ class "lighting" ] []
        , div [ class "reading-pile" ]
            [ div [ class "reading-pile__label" ] [ text "Reading Pile" ]
            , if model.showAgeGate then
                ageGate
                    { onVerify = VerifyAge
                    , onDismiss = DismissAgeGate
                    }

              else
                div [ class "reading-pile__scene" ]
                    [ div [ class "reading-pile__floor", attribute "aria-hidden" "true" ] []
                    , div [ class "reading-pile__chair-area" ]
                        [ case model.books of
                            NotAsked ->
                                text ""

                            Loading ->
                                div [ class "reading-pile__empty-msg" ]
                                    [ text "Loading your reading pile..." ]

                            Failure _ ->
                                p [ class "error" ]
                                    [ text "Could not load your reading pile. Please try again." ]

                            Success placements ->
                                if List.isEmpty placements then
                                    div [ class "reading-pile__empty-msg" ]
                                        [ text "Nothing on the pile right now. Move a book from your Antilibrary to start reading." ]

                                else
                                    viewBookPile model.selectedBookId placements
                        , div [ class "armchair", attribute "aria-hidden" "true" ]
                            [ div [ class "armchair__back" ] []
                            , div [ class "armchair__seat" ] []
                            , div [ class "armchair__arm armchair__arm--left" ] []
                            , div [ class "armchair__arm armchair__arm--right" ] []
                            , div [ class "armchair__leg armchair__leg--fl" ] []
                            , div [ class "armchair__leg armchair__leg--fr" ] []
                            , div [ class "armchair__leg armchair__leg--bl" ] []
                            , div [ class "armchair__leg armchair__leg--br" ] []
                            ]
                        ]
                    ]
            ]
        ]


viewBookPile : Maybe String -> List Placement -> Html Msg
viewBookPile selectedBookId placements =
    div [ class "book-pile", attribute "role" "list" ]
        (List.indexedMap (viewPiledBook selectedBookId) (List.take 50 placements))


viewPiledBook : Maybe String -> Int -> Placement -> Html Msg
viewPiledBook selectedBookId index placement =
    let
        bookData =
            case placement.book of
                Just bk ->
                    bk

                Nothing ->
                    { id = ""
                    , title = "Unknown Title"
                    , author = Nothing
                    , description = Nothing
                    , editions = []
                    , primaryEdition = Nothing
                    , editionCount = 0
                    , subjects = []
                    , visibilityTier = Types.Book.Public
                    }

        pageCount =
            Maybe.withDefault 200 (bookPageCount bookData)

        texture =
            pickTexture bookData.title

        spineW =
            Components.Spine.spineWidth pageCount

        spineH =
            Components.Spine.spineHeight pageCount

        offset =
            (modBy 5 (index * 3 + 2) - 2) * 3

        isSelected =
            selectedBookId == Just bookData.id

        bookClass =
            if isSelected then
                "book-pile__book book-pile__book--selected"

            else
                "book-pile__book"
    in
    button
        [ class bookClass
        , attribute "role" "listitem"
        , onMouseEnter (BookHovered bookData.id)
        , stopPropagationOn "click"
            (Decode.succeed ( BookClicked bookData, True ))
        , style "width" (String.fromInt spineH ++ "px")
        , style "height" (String.fromInt spineW ++ "px")
        , style "margin-left" (String.fromInt offset ++ "px")
        ]
        [ div [ class "book-pile__rotated-book" ]
            [ Components.Spine.book
                { pageCount = pageCount
                , wearLevel = Softened
                , texture = texture
                , title = bookData.title
                , author = Types.Book.authorName bookData
                , coverImageUrl = bookCoverImageUrl bookData
                }
            ]
        ]
