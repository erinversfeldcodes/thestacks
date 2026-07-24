module Page.Search exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , SnippetSegment(..)
    , init
    , parseSnippet
    , update
    , view
    )

import Api
import Components.FilterPanel exposing (FilterState, SortOrder(..), defaultFilterState, filterPanel)
import Components.SearchBar exposing (searchBar)
import Components.SortSelector exposing (sortSelector)
import Html exposing (Html, a, button, div, h1, h2, h3, input, label, mark, p, text)
import Html.Attributes exposing (checked, class, href, id, type_)
import Html.Events exposing (onCheck, onClick)
import Http
import Navigation.Route as Route
import Process
import Task
import Types.Book exposing (Book, authorName, bookPublicationYear)
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


type alias Model =
    { query : String
    , results : RemoteData Http.Error Api.SearchSections
    , readers : RemoteData Http.Error (List Api.PublicProfileSummary)
    , filters : FilterState
    , sort : SortOrder
    , filterPanelOpen : Bool
    , deepSearch : Bool
    , debounceCount : Int
    }


type Msg
    = QueryChanged String
    | ClearQuery
    | SearchCompleted (Result Http.Error Api.SearchSections)
    | ReadersCompleted (Result Http.Error (List Api.PublicProfileSummary))
    | DebounceExpired Int
    | SortChanged String
    | ToggleFilterPanel
    | YearFromChanged String
    | YearToChanged String
    | ClearFilters
    | DeepSearchToggled Bool
    | BookClicked String


type OutMsg
    = NoOut
    | SessionExpired
      -- A search result was activated: open the book detail overlay for this
      -- book id. Main handles this by opening the overlay over /search (URL
      -- unchanged, per the overlay convention / ADR-005), with the clicked row
      -- as the focus-return trigger (see #114, #289).
    | OpenOverlay String


init : Model
init =
    { query = ""
    , results = NotAsked
    , readers = NotAsked
    , filters = defaultFilterState
    , sort = ByRelevance
    , filterPanelOpen = False
    , deepSearch = False
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
                    -- so it fires with or without a token. The scope (title-only vs
                    -- deep) follows the current toggle state (#284).
                    bookCmd =
                        case maybeToken of
                            Just token ->
                                Api.searchBooks model.query model.deepSearch token SearchCompleted

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
                Ok sections ->
                    ( { model | results = Success sections }, Cmd.none, NoOut )

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

        DeepSearchToggled deep ->
            let
                newModel =
                    { model | deepSearch = deep }
            in
            -- Re-fire the current query under the new scope so the results
            -- update immediately (no re-typing). Only the book search re-runs —
            -- deep scope affects books, not people — and only when there is a
            -- token and a non-empty query; otherwise just flip the flag (#284).
            case ( maybeToken, String.isEmpty model.query ) of
                ( Just token, False ) ->
                    ( { newModel | results = Loading }
                    , Api.searchBooks model.query deep token SearchCompleted
                    , NoOut
                    )

                _ ->
                    ( newModel, Cmd.none, NoOut )

        BookClicked bookId ->
            ( model, Cmd.none, OpenOverlay bookId )


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
        , viewDeepSearchToggle model.deepSearch
        , case model.results of
            NotAsked ->
                p [ class "search-hint" ] [ text "Type a title, author, or ISBN to search the stacks." ]

            Loading ->
                div [ class "loading" ] [ text "Searching the stacks…" ]

            Failure _ ->
                p [ class "error" ] [ text "We couldn't reach the shelves just now. Give it a moment and try again." ]

            Success sections ->
                let
                    -- Sort and the year filter apply WITHIN each section: the same
                    -- `applyYearFilter`/`sortBooks` are run independently over the
                    -- collection hits and the platform hits (they are generic over
                    -- any `{ a | book : Book }`), so a section's ordering never
                    -- bleeds across the boundary.
                    visibleCollection =
                        sections.collection
                            |> applyYearFilter model.filters
                            |> sortBooks model.sort

                    visiblePlatform =
                        sections.platform
                            |> applyYearFilter model.filters
                            |> sortBooks model.sort

                    rawEmpty =
                        List.isEmpty sections.collection && List.isEmpty sections.platform

                    visibleEmpty =
                        List.isEmpty visibleCollection && List.isEmpty visiblePlatform
                in
                if visibleEmpty then
                    -- Distinguish "the query found nothing" from "the query found
                    -- books but the year filter hid them all" — the latter is
                    -- fixable by widening/clearing the filter, so say so.
                    if not rawEmpty && yearFilterActive model.filters then
                        p [ class "search-empty" ] [ text "No books in that year range — widen it or clear filters" ]

                    else
                        p [ class "search-empty" ] [ text "Nothing on the shelves matches that — yet." ]

                else
                    div [ class "search-results", testId "search-results" ]
                        [ viewCollectionSection visibleCollection
                        , viewPlatformSection visiblePlatform
                        ]
        , viewReadersSection model.readers
        ]


{-| The "Deep search" toggle: off by default, it opts the query into matching
book descriptions/reviews (not just titles) via `scope=deep` (#284). Flipping it
re-fires the current query with the new scope (see `update`, `DeepSearchToggled`).
-}
viewDeepSearchToggle : Bool -> Html Msg
viewDeepSearchToggle deep =
    label [ class "deep-search-toggle" ]
        [ input
            [ type_ "checkbox"
            , class "deep-search-toggle__checkbox"
            , testId "deep-search-toggle"
            , checked deep
            , onCheck DeepSearchToggled
            ]
            []
        , text "Deep search"
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


{-| Keep only hits whose book's publication year falls within the (optional)
range. When neither bound is set the list is returned unchanged. Generic over any
`{ a | book : Book }`, so it applies uniformly to collection and platform hits
without discarding their per-hit metadata (shelf / source).

A book with no known publication year is KEPT once a bound is active, rather than
silently vanishing: its range membership can't be confirmed either way, so hiding
it would misrepresent the collection. Such books are surfaced with an explicit
"Unknown year" label (see `viewResultButton`) so their presence is legible.

-}
applyYearFilter : FilterState -> List { a | book : Book } -> List { a | book : Book }
applyYearFilter filters hits =
    case ( filters.yearFrom, filters.yearTo ) of
        ( Nothing, Nothing ) ->
            hits

        _ ->
            List.filter (\hit -> bookWithinYearRange filters hit.book) hits


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


{-| Order the rendered hits by the selected sort. `ByRelevance` (the default) is a
passthrough: the backend already returns rows in `plainto_tsquery` rank order, so
keeping that order IS relevance ranking — there is nothing to sort on client-side.
The other orders re-sort the list. Generic over any `{ a | book : Book }` so the
same ordering runs over each section independently, preserving per-hit metadata.
-}
sortBooks : SortOrder -> List { a | book : Book } -> List { a | book : Book }
sortBooks sort hits =
    case sort of
        ByRelevance ->
            hits

        ByTitle ->
            List.sortBy (.book >> .title) hits

        ByAuthor ->
            List.sortBy (.book >> authorName) hits

        ByYear ->
            List.sortBy (.book >> bookPublicationYear >> Maybe.withDefault 0) hits


{-| "Your Collection": the viewer's own matching books, each tagged with the
shelf it sits on. Hidden entirely when empty so an empty-collection viewer sees
the platform-only view (#285).
-}
viewCollectionSection : List Api.CollectionHit -> Html Msg
viewCollectionSection hits =
    if List.isEmpty hits then
        text ""

    else
        div [ class "search-section search-section--collection", testId "search-collection" ]
            (h2 [ class "search-section__title" ] [ text "Your Collection" ]
                :: List.map viewCollectionHit hits
            )


{-| "On the Platform": platform-visible books, some carrying a discoverable label.
Hidden entirely when empty (collection-only view) (#285).
-}
viewPlatformSection : List Api.PlatformHit -> Html Msg
viewPlatformSection hits =
    if List.isEmpty hits then
        text ""

    else
        div [ class "search-section search-section--platform", testId "search-platform" ]
            (h2 [ class "search-section__title" ] [ text "On the Platform" ]
                :: List.map viewPlatformHit hits
            )


{-| A collection hit renders the book row with a "On your <Shelf> shelf" line —
the "where in your collection" answer US-1.5.1 always promised. Its deep-search
snippet (non-empty only when the match was on the description/review, not the
title) is carried through so the excerpt + "via deep search" label render (#284).
-}
viewCollectionHit : Api.CollectionHit -> Html Msg
viewCollectionHit hit =
    viewResultButton hit.book (Just ("On your " ++ bookshelfLabel hit.bookshelfName ++ " shelf")) hit.snippet


{-| A platform hit renders the book row with its discoverable-by-design label
(only when `source` is non-empty — a plain result carries no label), plus its
deep-search snippet when the match was on description/review text (#284).
-}
viewPlatformHit : Api.PlatformHit -> Html Msg
viewPlatformHit hit =
    viewResultButton hit.book (platformLabel hit) hit.snippet


{-| The label for a platform hit, or `Nothing` for a plain result. Labels are
only ever emitted by the backend for always-visible provenance (an active
`looking_for_home` advert or an active marketplace listing), so rendering them
here never leaks private shelf provenance (#285).
-}
platformLabel : Api.PlatformHit -> Maybe String
platformLabel hit =
    case hit.source of
        "looking_for_home" ->
            Just ("Looking for a home on " ++ hit.ownerHandle ++ "'s shelf")

        "listed" ->
            Just ("Listed by " ++ hit.ownerHandle ++ " for " ++ hit.price)

        _ ->
            Nothing


{-| Humanise a raw bookshelf name (`reading_pile` -> "Reading Pile") for display,
matching the canonical shelf labels used in Upload/Catalogue. Unknown names fall
through unchanged rather than being dropped.
-}
bookshelfLabel : String -> String
bookshelfLabel name =
    case name of
        "library" ->
            "Library"

        "antilibrary" ->
            "Antilibrary"

        "wishlist" ->
            "Wish List"

        "reading_pile" ->
            "Reading Pile"

        "looking_for_home" ->
            "Looking for a Home"

        other ->
            other


{-| A search result is a real `<button>` (natively keyboard-focusable and
Enter/Space-activatable — the accessible interactive element, mirroring the
shelf-spine pattern in `Page.Bookshelf.Helpers.viewClickableSpine`). Its stable
id `search-result-<bookId>` is the focus-return target Main hands to the overlay
so focus comes back to the clicked row on close (#114 / #289). The optional label
line carries the section's provenance (collection shelf / platform source); a
non-empty `snippet` (a deep-search description/review excerpt) renders the
highlighted excerpt and a "via deep search" line beneath it (#284).
-}
viewResultButton : Book -> Maybe String -> String -> Html Msg
viewResultButton book maybeLabel snippet =
    button
        [ class "search-result"
        , id ("search-result-" ++ book.id)
        , onClick (BookClicked book.id)
        ]
        ([ h3 [ class "search-result__title" ] [ text book.title ]
         , p [ class "search-result__author" ] [ text (authorName book) ]
         , case bookPublicationYear book of
            Just year ->
                p [ class "search-result__year" ] [ text (String.fromInt year) ]

            Nothing ->
                p [ class "search-result__year search-result__year--unknown" ] [ text "Unknown year" ]
         ]
            ++ (case maybeLabel of
                    Just label_ ->
                        [ p [ class "search-result__label" ] [ text label_ ] ]

                    Nothing ->
                        []
               )
            ++ viewSnippet snippet
        )


{-| Render a deep-search snippet excerpt and its "via deep search" provenance
line, but ONLY when the snippet is non-empty — a title match carries no snippet,
so it renders neither (#284). The `<mark>` runs in the excerpt are parsed into
styled `<mark>` elements (never injected as HTML — see `parseSnippet`).
-}
viewSnippet : String -> List (Html Msg)
viewSnippet snippet =
    if String.isEmpty snippet then
        []

    else
        [ p [ class "search-result__snippet" ]
            (List.map viewSnippetSegment (parseSnippet snippet))
        , p [ class "search-result__via-deep" ] [ text "via deep search" ]
        ]


{-| Render one parsed snippet segment: plain text as an escaped text node, a
highlighted run as a `<mark>` element (safe — the text goes through Elm's `text`,
which escapes; no innerHTML, so no injection).
-}
viewSnippetSegment : SnippetSegment -> Html Msg
viewSnippetSegment segment =
    case segment of
        Plain str ->
            text str

        Highlight str ->
            mark [ class "search-result__mark" ] [ text str ]


{-| A parsed snippet segment: either plain text or a `<mark>`-highlighted run.
-}
type SnippetSegment
    = Plain String
    | Highlight String


markOpen : String
markOpen =
    "<mark>"


markClose : String
markClose =
    "</mark>"


{-| Parse a `ts_headline` snippet string into plain / highlighted segments,
splitting on balanced `<mark>…</mark>` pairs. Elm cannot set innerHTML without a
port, so the `<mark>` markup is parsed HERE and rendered as styled `<mark>`
elements via the safe `text` API (which escapes) — never injected as HTML.

Malformed or unbalanced input is passed through verbatim as plain text rather
than dropped or falsely highlighted: an opening `<mark>` with no matching close
emits the remaining input as one plain segment (so the literal tag is shown,
escaped, not treated as a highlight). An empty string yields no segments.

-}
parseSnippet : String -> List SnippetSegment
parseSnippet input =
    case List.head (String.indexes markOpen input) of
        Nothing ->
            plainSegment input

        Just openIdx ->
            let
                before =
                    String.left openIdx input

                afterOpen =
                    String.dropLeft (openIdx + String.length markOpen) input
            in
            case List.head (String.indexes markClose afterOpen) of
                Nothing ->
                    -- Unbalanced: an open with no close. Emit the whole remaining
                    -- input verbatim as plain text — no false highlight.
                    plainSegment input

                Just closeIdx ->
                    let
                        highlighted =
                            String.left closeIdx afterOpen

                        rest =
                            String.dropLeft (closeIdx + String.length markClose) afterOpen
                    in
                    consPlain before (Highlight highlighted :: parseSnippet rest)


{-| A single plain segment for `str`, or none when `str` is empty (so empty runs
never produce phantom `Plain ""` segments).
-}
plainSegment : String -> List SnippetSegment
plainSegment str =
    if String.isEmpty str then
        []

    else
        [ Plain str ]


{-| Prepend `str` as a leading plain segment, dropping it when empty.
-}
consPlain : String -> List SnippetSegment -> List SnippetSegment
consPlain str segments =
    if String.isEmpty str then
        segments

    else
        Plain str :: segments
