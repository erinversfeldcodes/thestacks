module Components.FilterPanel exposing
    ( FilterState
    , SortOrder(..)
    , defaultFilterState
    , filterPanel
    )

import Html exposing (Html, button, div, input, label, text)
import Html.Attributes exposing (class, type_, value)
import Html.Events exposing (onClick, onInput)


type SortOrder
    = ByTitle
    | ByAuthor
    | ByYear
    | ByDateAdded


type alias FilterState =
    { shelfFilter : Maybe String
    , formatFilter : Maybe String
    , yearFrom : Maybe Int
    , yearTo : Maybe Int
    }


defaultFilterState : FilterState
defaultFilterState =
    { shelfFilter = Nothing
    , formatFilter = Nothing
    , yearFrom = Nothing
    , yearTo = Nothing
    }


filterPanel :
    { isOpen : Bool
    , filters : FilterState
    , onToggle : msg
    , onYearFrom : String -> msg
    , onYearTo : String -> msg
    , onClear : msg
    }
    -> Html msg
filterPanel config =
    div [ class "filter-panel" ]
        [ button
            [ class "filter-panel__toggle"
            , onClick config.onToggle
            ]
            [ text
                (if config.isOpen then
                    "Hide Filters"

                 else
                    "Show Filters"
                )
            ]
        , if config.isOpen then
            div [ class "filter-panel__body" ]
                [ div [ class "filter-panel__group" ]
                    [ label [ class "filter-panel__label" ] [ text "Year From" ]
                    , input
                        [ type_ "number"
                        , class "filter-panel__input"
                        , value
                            (config.filters.yearFrom
                                |> Maybe.map String.fromInt
                                |> Maybe.withDefault ""
                            )
                        , onInput config.onYearFrom
                        ]
                        []
                    ]
                , div [ class "filter-panel__group" ]
                    [ label [ class "filter-panel__label" ] [ text "Year To" ]
                    , input
                        [ type_ "number"
                        , class "filter-panel__input"
                        , value
                            (config.filters.yearTo
                                |> Maybe.map String.fromInt
                                |> Maybe.withDefault ""
                            )
                        , onInput config.onYearTo
                        ]
                        []
                    ]
                , button
                    [ class "filter-panel__clear"
                    , onClick config.onClear
                    ]
                    [ text "Clear Filters" ]
                ]

          else
            text ""
        ]
