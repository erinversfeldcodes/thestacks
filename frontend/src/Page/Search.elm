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
    , sort = ByRelevance
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
                        "title" ->
                            ByTitle

                        "author" ->
                            ByAuthor

                        "year" ->
                            ByYear

                        _ ->
                            ByRelevance
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
                p [ class "search-hint" ] [ text "Type a title, author, or ISBN to search the stacks." ]

            Loading ->
                div [ class "loading" ] [ text "Searching the stacks…" ]

            Failure _ ->
                p [ class "error" ] [ text "We couldn't reach the shelves just now. Give it a moment and try again." ]

            Success books ->
                let
                    visibleBooks =
                        books
                            |> applyYearFilter model.filters
                            |> sortBooks model.sort
                in
                if List.isEmpty visibleBooks then
                    -- Distinguish "the query found nothing" from "the query found
                    -- books but the year filter hid them all" — the latter is
                    -- fixable by widening/clearing the filter, so say so.
                    if not (List.isEmpty books) && yearFilterActive model.filters then
                        p [ class "search-empty" ] [ text "No books in that year range — widen it or clear filters" ]

                    else
                        p [ class "search-empty" ] [ text "Nothing on the shelves matches that — yet." ]

                else
                    div [ class "search-results", testId "search-results" ]
                        (List.map viewBookResult visibleBooks)
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
                , div [ class "loading" ] [ text "Searching the stacks…" ]
                ]

        Failure _ ->
            div [ class "search-readers", testId "search-readers" ]
                [ h2 [ class "search-readers__title" ] [ text "Readers" ]
                , p [ class "error" ] [ text "We couldn't reach the shelves just now. Give it a moment and try again." ]
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


{-| Keep only books whose publication year falls within the (optional) range.
When neither bound is set the list is returned unchanged.

A book with no known publication year is KEPT once a bound is active, rather than
silently vanishing: its range membership can't be confirmed either way, so hiding
it would misrepresent the collection. Such books are surfaced with an explicit
"Unknown year" label (see `viewBookResult`) so their presence is legible.

-}
applyYearFilter : FilterState -> List Book -> List Book
applyYearFilter filters books =
    case ( filters.yearFrom, filters.yearTo ) of
        ( Nothing, Nothing ) ->
            books

        _ ->
            List.filter (bookWithinYearRange filters) books


{-| True when either year bound is set — i.e. the year filter is narrowing the
results, so an empty visible list can be blamed on the filter rather than the query.
-}
yearFilterActive : FilterState -> Bool
yearFilterActive filters =
    filters.yearFrom /= Nothing || filters.yearTo /= Nothing


bookWithinYearRange : FilterState -> Book -> Bool
bookWithinYearRange filters book =
    case bookPublicationYear book of
        Nothing ->
            True

        Just year ->
            (case filters.yearFrom of
                Just from ->
                    year >= from

                Nothing ->
                    True
            )
                && (case filters.yearTo of
                        Just to ->
                            year <= to

                        Nothing ->
                            True
                   )


{-| Order the rendered results by the selected sort. `ByRelevance` (the default)
is a passthrough: the backend already returns rows in `plainto_tsquery` rank
order, so keeping that order IS relevance ranking — there is nothing to sort on
client-side. The other orders re-sort the list.
-}
sortBooks : SortOrder -> List Book -> List Book
sortBooks sort books =
    case sort of
        ByRelevance ->
            books

        ByTitle ->
            List.sortBy .title books

        ByAuthor ->
            List.sortBy authorName books

        ByYear ->
            List.sortBy (bookPublicationYear >> Maybe.withDefault 0) books


viewBookResult : Book -> Html Msg
viewBookResult book =
    div [ class "search-result" ]
        [ h3 [ class "search-result__title" ] [ text book.title ]
        , p [ class "search-result__author" ] [ text (authorName book) ]
        , case bookPublicationYear book of
            Just year ->
                p [ class "search-result__year" ] [ text (String.fromInt year) ]

            Nothing ->
                p [ class "search-result__year search-result__year--unknown" ] [ text "Unknown year" ]
        ]
