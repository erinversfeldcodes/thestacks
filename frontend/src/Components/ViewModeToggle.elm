module Components.ViewModeToggle exposing (ShelfViewMode(..), view)

import Html exposing (Html, button, div, text)
import Html.Attributes exposing (attribute, class)
import Html.Events exposing (onClick)


type ShelfViewMode
    = SpineView
    | ListView


view : ShelfViewMode -> (ShelfViewMode -> msg) -> Html msg
view currentMode onToggle =
    div [ class "view-mode-toggle", attribute "role" "group", attribute "aria-label" "View mode" ]
        [ button
            [ class
                (if currentMode == SpineView then
                    "view-mode-toggle__btn view-mode-toggle__btn--active"

                 else
                    "view-mode-toggle__btn"
                )
            , onClick (onToggle SpineView)
            , attribute "aria-pressed"
                (if currentMode == SpineView then
                    "true"

                 else
                    "false"
                )
            , attribute "aria-label" "Spine view"
            ]
            [ text "|||" ]
        , button
            [ class
                (if currentMode == ListView then
                    "view-mode-toggle__btn view-mode-toggle__btn--active"

                 else
                    "view-mode-toggle__btn"
                )
            , onClick (onToggle ListView)
            , attribute "aria-pressed"
                (if currentMode == ListView then
                    "true"

                 else
                    "false"
                )
            , attribute "aria-label" "List view"
            ]
            [ text "=" ]
        ]
