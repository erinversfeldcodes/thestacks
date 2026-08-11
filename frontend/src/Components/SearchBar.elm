module Components.SearchBar exposing (searchBar)

import Html exposing (Html, button, div, input, text)
import Html.Attributes exposing (attribute, class, placeholder, type_, value)
import Html.Events exposing (onClick, onInput)
import Util.TestId exposing (testId)


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
            , testId "search-input"
            , placeholder config.placeholder_
            , attribute "aria-label" config.placeholder_
            , value config.query
            , onInput config.onInput
            ]
            []
        , if String.isEmpty config.query then
            text ""

          else
            button
                [ class "search-bar__clear"
                , testId "search-clear"
                , attribute "aria-label" "Clear search"
                , onClick config.onClear
                ]
                [ text "✕" ]
        ]
