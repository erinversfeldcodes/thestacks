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
import Components.EmptyBookshelf exposing (emptyBookshelf)
import Components.Spine exposing (WearLevel(..), spine, spineWidth)
import Html exposing (Html, div, h2, p, text)
import Html.Attributes exposing (attribute, class, style)
import Http
import Navigation.Route exposing (Route(..))
import Page.Bookshelf.Helpers exposing (pickTexture)
import Types.Book
import Types.Placement exposing (Placement)
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { books : RemoteData Http.Error (List Placement)
    , showAgeGate : Bool
    }


type OutMsg
    = NoOut
    | NavigateTo Route


type Msg
    = BooksLoaded (Result Http.Error (List Placement))
    | VerifyAge
    | DismissAgeGate


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
    ( { books = Loading, showAgeGate = False }, cmd )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        BooksLoaded result ->
            case result of
                Ok placements ->
                    ( { model | books = Success placements }, Cmd.none, NoOut )

                Err (Http.BadStatus 403) ->
                    ( { model | books = Failure (Http.BadStatus 403), showAgeGate = True }, Cmd.none, NoOut )

                Err err ->
                    ( { model | books = Failure err }, Cmd.none, NoOut )

        VerifyAge ->
            ( model, Cmd.none, NavigateTo SettingsAgeVerification )

        DismissAgeGate ->
            ( { model | showAgeGate = False }, Cmd.none, NoOut )


view : Model -> Html Msg
view model =
    div [ class "page page--shelf shelf-reading-pile" ]
        [ div [ class "reading-nook" ]
            [ div [ class "reading-nook__lamp" ] []
            , div [ class "reading-nook__scene" ]
                [ div [ class "reading-nook__armchair", attribute "aria-hidden" "true" ]
                    [ div [ class "reading-nook__armchair-back" ] []
                    , div [ class "reading-nook__armchair-seat" ] []
                    , div [ class "reading-nook__armchair-arm reading-nook__armchair-arm--left" ] []
                    , div [ class "reading-nook__armchair-arm reading-nook__armchair-arm--right" ] []
                    ]
                , div [ class "reading-nook__side-table" ]
                    [ div [ class "reading-nook__table-top" ]
                        [ if model.showAgeGate then
                            ageGate
                                { onVerify = VerifyAge
                                , onDismiss = DismissAgeGate
                                }

                          else
                            case model.books of
                                NotAsked ->
                                    text ""

                                Loading ->
                                    div [ class "loading" ] [ text "Loading your reading pile..." ]

                                Failure _ ->
                                    p [ class "error" ]
                                        [ text "Could not load your reading pile. Please try again." ]

                                Success placements ->
                                    if List.isEmpty placements then
                                        emptyBookshelf
                                            { bookshelf = "reading_pile"
                                            , message =
                                                "Nothing on the pile right now. Move a book from your AntiLibrary to start reading."
                                            }

                                    else
                                        viewBookPile placements
                        ]
                    , div [ class "reading-nook__table-leg" ] []
                    ]
                ]
            , div [ class "reading-nook__rug", attribute "aria-hidden" "true" ] []
            , h2 [ class "reading-nook__title" ] [ text "Reading Pile" ]
            ]
        ]


viewBookPile : List Placement -> Html Msg
viewBookPile placements =
    div [ class "book-pile" ]
        (List.indexedMap viewStackedBook placements)


viewStackedBook : Int -> Placement -> Html Msg
viewStackedBook index placement =
    let
        ( bookTitle, author, pageCount ) =
            case placement.book of
                Just book ->
                    ( book.title, Types.Book.authorName book, Maybe.withDefault 200 book.pageCount )

                Nothing ->
                    ( "Unknown Title", "Unknown Author", 200 )

        thickness =
            spineWidth pageCount

        rotation =
            modBy 7 (index * 3 + 2) - 3

        rotationStr =
            "rotate(" ++ String.fromInt rotation ++ "deg)"

        texture =
            pickTexture bookTitle
    in
    div
        [ class "book-pile__book"
        , style "height" (String.fromInt thickness ++ "px")
        , style "transform" rotationStr
        ]
        [ spine
            { pageCount = pageCount
            , wearLevel = Softened
            , texture = texture
            , title = bookTitle
            , author = author
            }
        ]
