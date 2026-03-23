module Components.ISBNInput exposing
    ( isValidISBN
    , isbnInput
    , validateISBN10
    , validateISBN13
    )

import Html exposing (Html, div, input, p, text)
import Html.Attributes exposing (class, placeholder, type_, value)
import Html.Events exposing (onInput)
import Util.TestId exposing (testId)


validateISBN10 : String -> Bool
validateISBN10 raw =
    let
        digits =
            String.toList raw
                |> List.filter (\c -> c /= '-' && c /= ' ')
    in
    if List.length digits /= 10 then
        False

    else
        let
            charToValue : Int -> Char -> Maybe Int
            charToValue idx c =
                if idx == 9 && (c == 'X' || c == 'x') then
                    Just 10

                else
                    String.toInt (String.fromChar c)

            values =
                List.indexedMap charToValue digits

            allValid =
                List.all (\v -> v /= Nothing) values

            sumWeighted =
                List.indexedMap
                    (\i maybeV ->
                        case maybeV of
                            Just v ->
                                (10 - i) * v

                            Nothing ->
                                0
                    )
                    values
                    |> List.sum
        in
        allValid && modBy 11 sumWeighted == 0


validateISBN13 : String -> Bool
validateISBN13 raw =
    let
        digits =
            String.toList raw
                |> List.filter (\c -> c /= '-' && c /= ' ')
    in
    if List.length digits /= 13 then
        False

    else
        let
            weights =
                List.indexedMap
                    (\i _ ->
                        if modBy 2 i == 0 then
                            1

                        else
                            3
                    )
                    digits

            values =
                List.map (\c -> String.toInt (String.fromChar c)) digits

            allValid =
                List.all (\v -> v /= Nothing) values

            sumWeighted =
                List.map2
                    (\w maybeV ->
                        case maybeV of
                            Just v ->
                                w * v

                            Nothing ->
                                0
                    )
                    weights
                    values
                    |> List.sum
        in
        allValid && modBy 10 sumWeighted == 0


isValidISBN : String -> Bool
isValidISBN raw =
    let
        stripped =
            String.toList raw
                |> List.filter (\c -> c /= '-' && c /= ' ')
                |> String.fromList

        len =
            String.length stripped
    in
    if len == 10 then
        validateISBN10 raw

    else if len == 13 then
        validateISBN13 raw

    else
        False


isbnInput :
    { value : String
    , onInput : String -> msg
    , showError : Bool
    }
    -> Html msg
isbnInput config =
    let
        isValid =
            String.isEmpty config.value || isValidISBN config.value

        hasError =
            config.showError && not isValid && not (String.isEmpty config.value)

        inputClass =
            if hasError then
                "isbn-input isbn-input--error"

            else
                "isbn-input"
    in
    div [ class "isbn-input-wrapper" ]
        [ input
            [ type_ "text"
            , class inputClass
            , testId "upload-manual-isbn-input"
            , placeholder "Enter ISBN-10 or ISBN-13"
            , value config.value
            , onInput config.onInput
            ]
            []
        , if hasError then
            p [ class "isbn-input__error" ]
                [ text "Invalid ISBN checksum. Please check the number and try again." ]

          else
            text ""
        ]
