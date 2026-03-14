module Components.Spine exposing
    ( SpineTexture(..)
    , WearLevel(..)
    , spine
    , spineWidth
    )

import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, style, title)


type WearLevel
    = Pristine
    | Softened


type SpineTexture
    = Cloth
    | Leather


spineWidth : Int -> Int
spineWidth pageCount =
    max 8 (min 40 (pageCount // 10))


wearLevelClass : WearLevel -> String
wearLevelClass wearLevel =
    case wearLevel of
        Pristine ->
            "spine--pristine"

        Softened ->
            "spine--softened"


textureClass : SpineTexture -> String
textureClass texture =
    case texture of
        Cloth ->
            "spine--cloth"

        Leather ->
            "spine--leather"


{-| Deterministic color index from a string (title).
Produces a stable index so the same book always gets the same color.
-}
colorIndex : String -> Int
colorIndex s =
    modBy 8 (List.foldl (\c acc -> acc + Char.toCode c) 0 (String.toList s))


colorClass : Int -> String
colorClass idx =
    "spine--color-" ++ String.fromInt idx


bookmarkSvg : Html msg
bookmarkSvg =
    Html.node "svg"
        [ Html.Attributes.attribute "xmlns" "http://www.w3.org/2000/svg"
        , Html.Attributes.attribute "viewBox" "0 0 24 24"
        , Html.Attributes.attribute "width" "10"
        , Html.Attributes.attribute "height" "10"
        , Html.Attributes.attribute "fill" "currentColor"
        , class "spine__bookmark"
        ]
        [ Html.node "path"
            [ Html.Attributes.attribute "d" "M17 3H7c-1.1 0-2 .9-2 2v16l7-3 7 3V5c0-1.1-.9-2-2-2z" ]
            []
        ]


spine :
    { pageCount : Int
    , wearLevel : WearLevel
    , texture : SpineTexture
    , title : String
    , author : String
    }
    -> Html msg
spine config =
    let
        widthPx =
            spineWidth config.pageCount

        widthStr =
            String.fromInt widthPx ++ "px"

        idx =
            colorIndex config.title
    in
    div
        [ class "spine"
        , class (wearLevelClass config.wearLevel)
        , class (textureClass config.texture)
        , class (colorClass idx)
        , style "width" widthStr
        , title (config.title ++ " — " ++ config.author)
        ]
        [ div [ class "spine__edge spine__edge--top" ] []
        , bookmarkSvg
        , div [ class "spine__band spine__band--top" ] []
        , span [ class "spine__text" ]
            [ text (config.title ++ " · " ++ config.author) ]
        , div [ class "spine__band spine__band--bottom" ] []
        , div [ class "spine__edge spine__edge--bottom" ] []
        ]
