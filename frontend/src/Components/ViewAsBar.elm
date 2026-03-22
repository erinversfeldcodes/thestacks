module Components.ViewAsBar exposing (view)

import Html exposing (Html, a, div, span, text)
import Html.Attributes exposing (class, href)
import Url exposing (Url)


view : Url -> Html msg
view url =
    case getViewAs url of
        Just perspective ->
            div [ class "view-as-bar" ]
                [ span [ class "view-as-bar__text" ]
                    [ text ("Viewing as: " ++ perspective) ]
                , a
                    [ class "view-as-bar__exit"
                    , href (removeViewAs url)
                    ]
                    [ text "Exit preview" ]
                ]

        Nothing ->
            text ""


getViewAs : Url -> Maybe String
getViewAs url =
    url.query
        |> Maybe.andThen (findParam "view_as")


findParam : String -> String -> Maybe String
findParam key query =
    let
        pairs =
            String.split "&" query
    in
    pairs
        |> List.filterMap
            (\pair ->
                case String.split "=" pair of
                    [ k, v ] ->
                        if k == key then
                            Just v

                        else
                            Nothing

                    _ ->
                        Nothing
            )
        |> List.head


removeViewAs : Url -> String
removeViewAs url =
    let
        path =
            url.path

        newQuery =
            url.query
                |> Maybe.map
                    (\q ->
                        String.split "&" q
                            |> List.filter
                                (\pair ->
                                    case String.split "=" pair of
                                        [ k, _ ] ->
                                            k /= "view_as"

                                        _ ->
                                            True
                                )
                            |> String.join "&"
                    )
                |> Maybe.andThen
                    (\q ->
                        if String.isEmpty q then
                            Nothing

                        else
                            Just q
                    )
    in
    case newQuery of
        Just q ->
            path ++ "?" ++ q

        Nothing ->
            path
