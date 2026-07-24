module Components.SortSelector exposing (sortSelector)

import Components.FilterPanel exposing (SortOrder(..))
import Html exposing (Html, div, label, option, select, text)
import Html.Attributes exposing (class, selected, value)
import Html.Events exposing (onInput)
import Util.TestId exposing (testId)


sortSelector :
    { current : SortOrder
    , onChange : String -> msg
    }
    -> Html msg
sortSelector config =
    div [ class "sort-selector" ]
        [ label [ class "sort-selector__label" ] [ text "Sort by" ]
        , select
            [ class "sort-selector__select"
            , testId "sort-selector"
            , onInput config.onChange
            ]
            (List.map (viewOption config.current) options)
        ]


{-| The selectable sort orders, in display order. "Relevance" leads because it is
the default: it preserves the backend's `plainto_tsquery` ranking (a passthrough,
see `Page.Search.sortBooks`). The rest re-order the results client-side.
-}
options : List ( String, String, SortOrder )
options =
    [ ( "relevance", "Relevance", ByRelevance )
    , ( "title", "Title", ByTitle )
    , ( "author", "Author", ByAuthor )
    , ( "year", "Year", ByYear )
    ]


{-| Render one option, marked `selected` when it matches the current sort so the
dropdown reflects `model.sort` even when it is set programmatically (controlled).
-}
viewOption : SortOrder -> ( String, String, SortOrder ) -> Html msg
viewOption current ( optValue, optLabel, optSort ) =
    option
        [ value optValue
        , selected (optSort == current)
        ]
        [ text optLabel ]
