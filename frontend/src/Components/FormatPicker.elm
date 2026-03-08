module Components.FormatPicker exposing (formatPicker)

import Html exposing (Html, button, div, text)
import Html.Attributes exposing (class)
import Html.Events exposing (onClick)
import Types.Placement exposing (Format(..), formatToString)


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
                in
                button
                    [ class ("format-picker__btn " ++ selectedClass)
                    , onClick (config.onToggle format)
                    ]
                    [ text (formatLabel format) ]
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
