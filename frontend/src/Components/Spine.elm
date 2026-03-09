module Components.Spine exposing
    ( WearLevel(..)
    , spine
    , spineWidth
    )

import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, style, title)


type WearLevel
    = Pristine
    | Softened
    | Cracking
    | WellRead
    | WellLoved


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

        Cracking ->
            "spine--cracking"

        WellRead ->
            "spine--wellread"

        WellLoved ->
            "spine--wellloved"


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
    in
    div
        [ class "spine"
        , class (wearLevelClass config.wearLevel)
        , style "width" widthStr
        , title (config.title ++ " — " ++ config.author)
        ]
        [ bookmarkSvg
        , span [ class "spine__text" ]
            [ text (config.title ++ " · " ++ config.author) ]
        ]
