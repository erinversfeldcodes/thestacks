module Components.SearchBar exposing (searchBar)

import Html exposing (Html, button, div, input, text)
import Html.Attributes exposing (class, placeholder, type_, value)
import Html.Events exposing (onClick, onInput)


searchBar :
    { query : String
    , onInput : String -> msg
    , onClear : msg
    , placeholder_ : String
    }
    -> Html msg
searchBar config =
    div [ class "search-bar" ]
        [ div [ class "search-bar__icon" ] [ text "🔍" ]
        , input
            [ type_ "text"
            , class "search-bar__input"
            , placeholder config.placeholder_
            , value config.query
            , onInput config.onInput
            ]
            []
        , if String.isEmpty config.query then
            text ""

          else
            button
                [ class "search-bar__clear"
                , onClick config.onClear
                ]
                [ text "✕" ]
        ]
