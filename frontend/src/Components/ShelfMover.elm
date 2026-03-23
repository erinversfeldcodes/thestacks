module Components.ShelfMover exposing (shelfMover)

import Html exposing (Html, button, div, option, select, span, text)
import Html.Attributes exposing (attribute, class, selected, value)
import Html.Events exposing (onClick, onInput)
import Util.TestId exposing (testId)


allBookshelves : List { value : String, label : String }
allBookshelves =
    [ { value = "library", label = "Library" }
    , { value = "antilibrary", label = "Antilibrary" }
    , { value = "wishlist", label = "Wish List" }
    , { value = "reading_pile", label = "Reading Pile" }
    , { value = "looking_for_home", label = "Looking for a Home" }
    ]


shelfMover :
    { currentBookshelf : String
    , selectedBookshelf : String
    , onSelectBookshelf : String -> msg
    , onMove : msg
    }
    -> Html msg
shelfMover config =
    div [ class "shelf-mover" ]
        [ span [ class "shelf-mover__label" ] [ text "Move to:" ]
        , select
            [ class "shelf-mover__select"
            , testId "shelf-mover-select"
            , attribute "aria-label" "Target bookshelf"
            , onInput config.onSelectBookshelf
            ]
            (List.map
                (\bookshelf ->
                    option
                        [ value bookshelf.value
                        , selected (bookshelf.value == config.selectedBookshelf)
                        ]
                        [ text bookshelf.label ]
                )
                (List.filter (\s -> s.value /= config.currentBookshelf) allBookshelves)
            )
        , button
            [ class "shelf-mover__btn"
            , testId "shelf-mover-btn"
            , onClick config.onMove
            ]
            [ text "Move" ]
        ]
