module Components.EmptyBookshelf exposing (emptyBookshelf)

import Html exposing (Html, div, p, text)
import Html.Attributes exposing (class)


emptyBookshelf : { bookshelf : String, message : String } -> Html msg
emptyBookshelf config =
    div [ class "empty-shelf" ]
        [ div [ class "empty-shelf__icon" ] [ text "📚" ]
        , p [ class "empty-shelf__message" ] [ text config.message ]
        ]
