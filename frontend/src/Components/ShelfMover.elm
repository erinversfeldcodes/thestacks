module Components.ShelfMover exposing (shelfMover)

import Html exposing (Html, button, div, option, select, text)
import Html.Attributes exposing (class, selected, value)
import Html.Events exposing (onClick, onInput)


allShelves : List { value : String, label : String }
allShelves =
    [ { value = "library", label = "Library" }
    , { value = "antilibrary", label = "Antilibrary" }
    , { value = "wishlist", label = "Wish List" }
    , { value = "reading_pile", label = "Reading Pile" }
    , { value = "looking_for_home", label = "Looking for a Home" }
    ]


shelfMover :
    { currentShelf : String
    , selectedShelf : String
    , onSelectShelf : String -> msg
    , onMove : msg
    }
    -> Html msg
shelfMover config =
    div [ class "shelf-mover" ]
        [ select
            [ class "shelf-mover__select"
            , onInput config.onSelectShelf
            ]
            (List.map
                (\shelf ->
                    option
                        [ value shelf.value
                        , selected (shelf.value == config.selectedShelf)
                        ]
                        [ text shelf.label ]
                )
                (List.filter (\s -> s.value /= config.currentShelf) allShelves)
            )
        , button
            [ class "shelf-mover__btn"
            , onClick config.onMove
            ]
            [ text "Move to Shelf" ]
        ]
