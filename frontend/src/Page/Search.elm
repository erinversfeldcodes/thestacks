module Page.Search exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api
import Components.FilterPanel exposing (FilterState, SortOrder(..), defaultFilterState, filterPanel)
import Components.SearchBar exposing (searchBar)
import Components.SortSelector exposing (sortSelector)
import Html exposing (Html, a, div, h1, h2, h3, p, text)
import Html.Attributes exposing (class, href)
import Http
import Navigation.Route as Route
import Process
import Task
import Types.Book exposing (Book, authorName, bookPublicationYear)
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


type alias Model =
    { query : String
    , results : RemoteData Http.Error (List Book)
    , readers : RemoteData Http.Error (List Api.PublicProfileSummary)
    , filters : FilterState
    , sort : SortOrder
    , filterPanelOpen : Bool
    , debounceCount : Int
    }


type Msg
    = QueryChanged String
    | ClearQuery
    | SearchCompleted (Result Http.Error (List Book))
    | ReadersCompleted (Result Http.Error (List Api.PublicProfileSummary))
    | DebounceExpired Int
    | SortChanged String
    | ToggleFilterPanel
    | YearFromChanged String
    | YearToChanged String
    | ClearFilters


type OutMsg
    = NoOut
    | SessionExpired


init : Model
init =
    { query = ""
    , results = NotAsked
    , readers = NotAsked
    , filters = defaultFilterState
    , sort = ByTitle
    , filterPanelOpen = False
    , debounceCount = 0
    }


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
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
                    -- Book search is authenticated-only; with no token it never
                    -- fires, so stay on the hint rather than a spinner that would
                    -- never resolve for an anonymous visitor. People search below
                    -- still runs (optional-auth).
                    if String.isEmpty query || maybeToken == Nothing then
                        NotAsked

                    else
                        Loading
                , readers =
                    if String.isEmpty query then
                        NotAsked

                    else
                        Loading
              }
            , debounceCmd
            , NoOut
            )

        ClearQuery ->
            ( { model | query = "", results = NotAsked, readers = NotAsked }, Cmd.none, NoOut )

        DebounceExpired count ->
            if count == model.debounceCount && not (String.isEmpty model.query) then
                let
                    -- Book search is authenticated; people search is optional-auth
                    -- so it fires with or without a token.
                    bookCmd =
                        case maybeToken of
                            Just token ->
                                Api.searchBooks model.query token SearchCompleted

                            Nothing ->
                                Cmd.none

                    readersCmd =
                        Api.searchUsers maybeToken model.query ReadersCompleted
                in
                ( model, Cmd.batch [ bookCmd, readersCmd ], NoOut )

            else
                ( model, Cmd.none, NoOut )

        SearchCompleted result ->
            case result of
                Ok books ->
                    ( { model | results = Success books }, Cmd.none, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | results = Failure err }, Cmd.none, NoOut )

        ReadersCompleted result ->
            case result of
                Ok readers ->
                    ( { model | readers = Success readers }, Cmd.none, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | readers = Failure err }, Cmd.none, NoOut )

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
            ( { model | sort = newSort }, Cmd.none, NoOut )

        ToggleFilterPanel ->
            ( { model | filterPanelOpen = not model.filterPanelOpen }, Cmd.none, NoOut )

        YearFromChanged str ->
            let
                oldFilters =
                    model.filters

                newFilters =
                    { oldFilters | yearFrom = String.toInt str }
            in
            ( { model | filters = newFilters }, Cmd.none, NoOut )

        YearToChanged str ->
            let
                oldFilters =
                    model.filters

                newFilters =
                    { oldFilters | yearTo = String.toInt str }
            in
            ( { model | filters = newFilters }, Cmd.none, NoOut )

        ClearFilters ->
            ( { model | filters = defaultFilterState }, Cmd.none, NoOut )


view : Model -> Html Msg
view model =
    div [ class "page page--search", testId "search-page" ]
        [ h1 [ class "page__title" ] [ text "Search books & readers" ]
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
        , viewReadersSection model.readers
        ]


viewReadersSection : RemoteData Http.Error (List Api.PublicProfileSummary) -> Html Msg
viewReadersSection readers =
    case readers of
        NotAsked ->
            text ""

        Loading ->
            div [ class "search-readers", testId "search-readers" ]
                [ h2 [ class "search-readers__title" ] [ text "Readers" ]
                , div [ class "loading" ] [ text "Searching..." ]
                ]

        Failure _ ->
            div [ class "search-readers", testId "search-readers" ]
                [ h2 [ class "search-readers__title" ] [ text "Readers" ]
                , p [ class "error" ] [ text "Reader search failed. Please try again." ]
                ]

        Success people ->
            div [ class "search-readers", testId "search-readers" ]
                [ h2 [ class "search-readers__title" ] [ text "Readers" ]
                , if List.isEmpty people then
                    p [ class "search-empty" ] [ text "No readers found matching your search." ]

                  else
                    div [ class "search-readers__list", testId "search-readers-results" ]
                        (List.map viewReaderCard people)
                ]


viewReaderCard : Api.PublicProfileSummary -> Html Msg
viewReaderCard person =
    a
        [ class "reader-card"
        , href (Route.toPath (Route.Profile person.handle))
        , testId "reader-card"
        ]
        [ h3 [ class "reader-card__name" ] [ text person.displayName ]
        , p [ class "reader-card__handle" ] [ text ("@" ++ person.handle) ]
        , case viewReaderLocation person of
            Just loc ->
                p [ class "reader-card__location" ] [ text loc ]

            Nothing ->
                text ""
        ]


viewReaderLocation : Api.PublicProfileSummary -> Maybe String
viewReaderLocation person =
    case ( person.city, person.countryCode ) of
        ( "", "" ) ->
            Nothing

        ( "", country ) ->
            Just country

        ( city, "" ) ->
            Just city

        ( city, country ) ->
            Just (city ++ ", " ++ country)


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
