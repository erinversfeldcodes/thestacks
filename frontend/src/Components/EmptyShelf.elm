module Components.EmptyShelf exposing (emptyShelf)

import Html exposing (Html, div, p, text)
import Html.Attributes exposing (class)


emptyShelf : { shelf : String, message : String } -> Html msg
emptyShelf config =
    div [ class "empty-shelf" ]
        [ div [ class "empty-shelf__icon" ] [ text "📚" ]
        , p [ class "empty-shelf__message" ] [ text config.message ]
        ]
