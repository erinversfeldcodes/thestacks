module Components.BookList exposing (SortColumn(..), SortDirection(..), SortState, view)

import Html exposing (Html, div, span, table, tbody, td, text, th, thead, tr)
import Html.Attributes exposing (attribute, class, scope)
import Html.Events exposing (onClick)
import Types.Book exposing (Book, authorName, bookPageCount)
import Types.Placement exposing (Format(..), Placement)


type SortColumn
    = Title
    | Author
    | PageCount
    | DateAdded
    | Formats


type SortDirection
    = Asc
    | Desc


type alias SortState =
    { column : SortColumn
    , direction : SortDirection
    }


view : SortState -> (SortColumn -> msg) -> (Book -> msg) -> List Placement -> Html msg
view sortState onSort onBookClicked placements =
    let
        sorted =
            sortPlacements sortState placements
    in
    table [ class "book-list", attribute "role" "table" ]
        [ thead []
            [ tr []
                [ sortableHeader sortState onSort Title "Title"
                , sortableHeader sortState onSort Author "Author"
                , sortableHeader sortState onSort PageCount "Pages"
                , sortableHeader sortState onSort DateAdded "Date Added"
                , sortableHeader sortState onSort Formats "Formats"
                ]
            ]
        , tbody []
            (List.map (viewRow onBookClicked) sorted)
        ]


sortableHeader : SortState -> (SortColumn -> msg) -> SortColumn -> String -> Html msg
sortableHeader sortState onSort column label =
    let
        indicator =
            if sortState.column == column then
                case sortState.direction of
                    Asc ->
                        span [ class "book-list__sort-indicator" ] [ text " ^" ]

                    Desc ->
                        span [ class "book-list__sort-indicator" ] [ text " v" ]

            else
                text ""

        ariaSort =
            if sortState.column == column then
                case sortState.direction of
                    Asc ->
                        "ascending"

                    Desc ->
                        "descending"

            else
                "none"
    in
    th
        [ scope "col"
        , onClick (onSort column)
        , attribute "aria-sort" ariaSort
        ]
        [ text label, indicator ]


viewRow : (Book -> msg) -> Placement -> Html msg
viewRow onBookClicked placement =
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
    in
    tr
        [ class "book-list__row"
        , onClick (onBookClicked bookData)
        , attribute "role" "row"
        ]
        [ td [] [ text bookData.title ]
        , td [] [ text (authorName bookData) ]
        , td []
            [ text
                (case bookPageCount bookData of
                    Just pages ->
                        String.fromInt pages

                    Nothing ->
                        "-"
                )
            ]
        , td []
            [ text
                (case placement.placedAt of
                    Just date ->
                        String.left 10 date

                    Nothing ->
                        "-"
                )
            ]
        , td []
            [ div [ class "book-list__formats" ]
                (List.map viewFormatBadge placement.formats)
            ]
        ]


viewFormatBadge : Format -> Html msg
viewFormatBadge format =
    span [ class "book-list__format-badge" ]
        [ text (formatLabel format) ]


formatLabel : Format -> String
formatLabel format =
    case format of
        Physical ->
            "Physical"

        EBook ->
            "eBook"

        Audiobook ->
            "Audiobook"


sortPlacements : SortState -> List Placement -> List Placement
sortPlacements sortState placements =
    let
        compareFn =
            case sortState.column of
                Title ->
                    \a b -> compare (placementTitle a) (placementTitle b)

                Author ->
                    \a b -> compare (placementAuthor a) (placementAuthor b)

                PageCount ->
                    \a b -> compare (placementPageCount a) (placementPageCount b)

                DateAdded ->
                    \a b -> compare (placementDate a) (placementDate b)

                Formats ->
                    \a b -> compare (List.length a.formats) (List.length b.formats)

        sorted =
            List.sortWith compareFn placements
    in
    case sortState.direction of
        Asc ->
            sorted

        Desc ->
            List.reverse sorted


placementTitle : Placement -> String
placementTitle p =
    case p.book of
        Just bk ->
            String.toLower bk.title

        Nothing ->
            ""


placementAuthor : Placement -> String
placementAuthor p =
    case p.book of
        Just bk ->
            String.toLower (authorName bk)

        Nothing ->
            ""


placementPageCount : Placement -> Int
placementPageCount p =
    case p.book of
        Just bk ->
            Maybe.withDefault 0 (bookPageCount bk)

        Nothing ->
            0


placementDate : Placement -> String
placementDate p =
    Maybe.withDefault "" p.placedAt
