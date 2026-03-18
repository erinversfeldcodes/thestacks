module Components.FormatPicker exposing (formatPicker)

import Html exposing (Html, button, div, span, text)
import Html.Attributes exposing (attribute, class, title)
import Html.Events exposing (onClick)
import Types.Placement exposing (Format(..))


formatPicker :
    { selected : List Format
    , onToggle : Format -> msg
    }
    -> Html msg
formatPicker config =
    div [ class "format-picker" ]
        (List.map
            (\format ->
                let
                    isSelected =
                        List.member format config.selected

                    selectedClass =
                        if isSelected then
                            "format-picker__btn--selected"

                        else
                            ""

                    ariaPressedValue =
                        if isSelected then
                            "true"

                        else
                            "false"
                in
                button
                    [ class ("format-picker__btn " ++ selectedClass)
                    , onClick (config.onToggle format)
                    , title (formatLabel format)
                    , attribute "aria-pressed" ariaPressedValue
                    ]
                    [ span [ class "format-picker__icon" ]
                        [ text (formatIcon isSelected format) ]
                    , span [ class "format-picker__label" ]
                        [ text (formatLabel format) ]
                    ]
            )
            [ Physical, EBook, Audiobook ]
        )


formatLabel : Format -> String
formatLabel format =
    case format of
        Physical ->
            "Physical"

        EBook ->
            "eBook"

        Audiobook ->
            "Audiobook"


formatIcon : Bool -> Format -> String
formatIcon owned format =
    case ( format, owned ) of
        ( Physical, True ) ->
            "[■]"

        ( Physical, False ) ->
            "[ ]"

        ( EBook, True ) ->
            "{■}"

        ( EBook, False ) ->
            "{ }"

        ( Audiobook, True ) ->
            "(■)"

        ( Audiobook, False ) ->
            "( )"
