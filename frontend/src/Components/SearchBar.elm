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

            -- The placeholder is not an accessible name — it vanishes on input
            -- and several screen readers ignore it — so the search field would
            -- otherwise be announced as an unlabelled "edit text" (#318 TR-6).
            -- Reusing the placeholder copy keeps the label and the visible hint
            -- one string.
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

                -- The button's only content is a "✕" glyph, which has no
                -- accessible name of its own (#318 TR-6).
                , attribute "aria-label" "Clear search"
                , onClick config.onClear
                ]
                [ text "✕" ]
        ]
