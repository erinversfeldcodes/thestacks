module Page.Search exposing
    ( Model
    , Msg(..)
    , init
    , update
    , view
    )

import Api
import Components.FilterPanel exposing (FilterState, SortOrder(..), defaultFilterState, filterPanel)
import Components.SearchBar exposing (searchBar)
import Components.SortSelector exposing (sortSelector)
import Html exposing (Html, div, h1, h3, p, text)
import Html.Attributes exposing (class)
import Http
import Process
import Task
import Types.Book exposing (Book, authorName, bookPublicationYear)
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


type alias Model =
    { query : String
    , results : RemoteData Http.Error (List Book)
    , filters : FilterState
    , sort : SortOrder
    , filterPanelOpen : Bool
    , debounceCount : Int
    }


type Msg
    = QueryChanged String
    | ClearQuery
    | SearchCompleted (Result Http.Error (List Book))
    | DebounceExpired Int
    | SortChanged String
    | ToggleFilterPanel
    | YearFromChanged String
    | YearToChanged String
    | ClearFilters


init : Model
init =
    { query = ""
    , results = NotAsked
    , filters = defaultFilterState
    , sort = ByTitle
    , filterPanelOpen = False
    , debounceCount = 0
    }


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg )
update msg model maybeToken =
    case msg of
        QueryChanged query ->
            let
                newCount =
                    model.debounceCount + 1

                debounceCmd =
                    Task.perform (\_ -> DebounceExpired newCount)
                        (Process.sleep 300)
            in
            ( { model
                | query = query
                , debounceCount = newCount
                , results =
                    if String.isEmpty query then
                        NotAsked

                    else
                        Loading
              }
            , debounceCmd
            )

        ClearQuery ->
            ( { model | query = "", results = NotAsked }, Cmd.none )

        DebounceExpired count ->
            if count == model.debounceCount && not (String.isEmpty model.query) then
                let
                    cmd =
                        case maybeToken of
                            Just token ->
                                Api.searchBooks model.query token SearchCompleted

                            Nothing ->
                                Cmd.none
                in
                ( model, cmd )

            else
                ( model, Cmd.none )

        SearchCompleted result ->
            case result of
                Ok books ->
                    ( { model | results = Success books }, Cmd.none )

                Err err ->
                    ( { model | results = Failure err }, Cmd.none )

        SortChanged sortStr ->
            let
                newSort =
                    case sortStr of
                        "author" ->
                            ByAuthor

                        "year" ->
                            ByYear

                        "date_added" ->
                            ByDateAdded

                        _ ->
                            ByTitle
            in
            ( { model | sort = newSort }, Cmd.none )

        ToggleFilterPanel ->
            ( { model | filterPanelOpen = not model.filterPanelOpen }, Cmd.none )

        YearFromChanged str ->
            let
                oldFilters =
                    model.filters

                newFilters =
                    { oldFilters | yearFrom = String.toInt str }
            in
            ( { model | filters = newFilters }, Cmd.none )

        YearToChanged str ->
            let
                oldFilters =
                    model.filters

                newFilters =
                    { oldFilters | yearTo = String.toInt str }
            in
            ( { model | filters = newFilters }, Cmd.none )

        ClearFilters ->
            ( { model | filters = defaultFilterState }, Cmd.none )


view : Model -> Html Msg
view model =
    div [ class "page page--search", testId "search-page" ]
        [ h1 [ class "page__title" ] [ text "Search Books" ]
        , searchBar
            { query = model.query
            , onInput = QueryChanged
            , onClear = ClearQuery
            , placeholder_ = "Search by title, author, or ISBN..."
            }
        , sortSelector
            { current = model.sort
            , onChange = SortChanged
            }
        , filterPanel
            { isOpen = model.filterPanelOpen
            , filters = model.filters
            , onToggle = ToggleFilterPanel
            , onYearFrom = YearFromChanged
            , onYearTo = YearToChanged
            , onClear = ClearFilters
            }
        , case model.results of
            NotAsked ->
                p [ class "search-hint" ] [ text "Enter a search term above to find books." ]

            Loading ->
                div [ class "loading" ] [ text "Searching..." ]

            Failure _ ->
                p [ class "error" ] [ text "Search failed. Please try again." ]

            Success books ->
                if List.isEmpty books then
                    p [ class "search-empty" ] [ text "No books found matching your search." ]

                else
                    div [ class "search-results", testId "search-results" ]
                        (List.map viewBookResult books)
        ]


viewBookResult : Book -> Html Msg
viewBookResult book =
    div [ class "search-result" ]
        [ h3 [ class "search-result__title" ] [ text book.title ]
        , p [ class "search-result__author" ] [ text (authorName book) ]
        , case bookPublicationYear book of
            Just year ->
                p [ class "search-result__year" ] [ text (String.fromInt year) ]

            Nothing ->
                text ""
        ]
