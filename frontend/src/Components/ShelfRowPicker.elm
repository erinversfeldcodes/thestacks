module Components.ShelfRowPicker exposing (shelfRowPicker)

{-| Picks which physical shelf row inside one bookcase a book sits on.

⛔ Not `Components.ShelfMover`, which sits beside it on the same page and looks
almost the same. That one moves a book between BOOKSHELVES — the five named
collections a reader keeps. This one moves it between the SHELF ROWS of the
bookcase the book is already in, and cannot leave that bookcase at all.

The rows arrive as an ordered list of ids because a row has no name: it is
"the third shelf down", so its position in the list is its identity, exactly as
`Components.ShelfOrganiser` renders it.

-}

import Html exposing (Html, button, div, option, select, span, text)
import Html.Attributes exposing (attribute, class, disabled, selected, value)
import Html.Events exposing (onClick, onInput)
import Types.Shelf exposing (rowLabel)
import Util.TestId exposing (testId)


shelfRowPicker :
    { rowIds : List String
    , currentRowId : Maybe String
    , selectedRowId : String
    , busy : Bool
    , onSelectRow : String -> msg
    , onMove : msg
    }
    -> Html msg
shelfRowPicker config =
    div [ class "shelf-row-picker" ]
        [ span [ class "shelf-row-picker__label" ] [ text "Move to row:" ]
        , select
            [ class "shelf-row-picker__select"
            , testId "shelf-row-picker-select"
            , attribute "aria-label" "Target shelf row"
            , disabled config.busy
            , onInput config.onSelectRow
            ]
            (config.rowIds
                |> List.indexedMap (\index rowId -> ( rowId, rowLabel index ))
                |> List.filter (\( rowId, _ ) -> Just rowId /= config.currentRowId)
                |> List.map
                    (\( rowId, label ) ->
                        option
                            [ value rowId
                            , selected (rowId == config.selectedRowId)
                            ]
                            [ text label ]
                    )
            )
        , button
            [ class "shelf-row-picker__btn"
            , testId "shelf-row-picker-btn"
            , disabled config.busy
            , onClick config.onMove
            ]
            [ text "Move" ]
        ]
