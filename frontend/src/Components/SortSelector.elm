module Components.SortSelector exposing (sortSelector)

import Components.FilterPanel exposing (SortOrder(..))
import Html exposing (Html, div, label, option, select, text)
import Html.Attributes exposing (class, value)
import Html.Events exposing (onInput)


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
            , onInput config.onChange
            ]
            [ option [ value "title" ] [ text "Title" ]
            , option [ value "author" ] [ text "Author" ]
            , option [ value "year" ] [ text "Year" ]
            , option [ value "date_added" ] [ text "Date Added" ]
            ]
        ]
