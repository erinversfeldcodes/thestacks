module Components.Spine exposing
    ( SpineTexture(..)
    , WearLevel(..)
    , book
    , spineHeight
    , spineLean
    , spineWidth
    , textureUrl
    )

import Bitwise
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (attribute, class, style, title)
import Util.TestId exposing (testId)


type WearLevel
    = Pristine
    | Softened


type SpineTexture
    = Cloth
    | Leather


{-| Deterministic hash of a string, matching the JS mockup:

    let h = 0;
    for (let i = 0; i < s.length; i++) h = ((h << 5) - h + s.charCodeAt(i)) | 0;
    return Math.abs(h);

Elm uses arbitrary-precision integers so we mask to 32-bit with Bitwise
operations to match the JS `| 0` truncation behaviour then take abs.

-}
hash : String -> Int
hash s =
    let
        fold c acc =
            let
                shifted =
                    Bitwise.shiftLeftBy 5 acc - acc + Char.toCode c

                masked =
                    Bitwise.or shifted 0
            in
            masked
    in
    abs (List.foldl fold 0 (String.toList s))


{-| Spine width in pixels from page count.
Matches mockup: max(35, min(55, round(pages / 12)))
-}
spineWidth : Int -> Int
spineWidth pageCount =
    max 35 (min 55 (round (toFloat pageCount / 12)))


{-| Spine height in pixels from page count.
Matches mockup: round(238 + min(pages/750, 1) \* 48 + hash(String(pages)) % 8)
-}
spineHeight : Int -> Int
spineHeight pageCount =
    let
        base =
            238

        growth =
            min (toFloat pageCount / 750) 1 * 48

        jitter =
            modBy 8 (hash (String.fromInt pageCount))
    in
    round (toFloat base + growth) + jitter


{-| Slight lean angle in degrees from title.
Matches mockup: ((hash(title) % 16) - 8) / 10
-}
spineLean : String -> Float
spineLean titleStr =
    toFloat (modBy 16 (hash titleStr) - 8) / 10


{-| Simple color index (0-5) for selecting a texture palette.
-}
colorIndex : String -> Int
colorIndex s =
    modBy 6 (hash s)


{-| Whether text should use gold foil colouring.
Matches mockup logic: (hash(title+'g') % 100) / 100 < goldProbability
-}
useGold : String -> Float -> Bool
useGold titleStr goldProbability =
    let
        roll =
            toFloat (modBy 100 (hash (titleStr ++ "g"))) / 100
    in
    roll < goldProbability


{-| Texture data matching the mockup palette.
Returns ( bgColor, textColor, goldProbability, isLeather)
-}
textureData : Int -> { bg : String, text_ : String, gold : Float, leather : Bool }
textureData idx =
    case idx of
        0 ->
            { bg = "#5c2030", text_ = "#d4c4a0", gold = 0.6, leather = True }

        1 ->
            { bg = "#2a4a30", text_ = "#d4c4a0", gold = 0.5, leather = True }

        2 ->
            { bg = "#1e2848", text_ = "#c8b890", gold = 0.7, leather = True }

        3 ->
            { bg = "#5a4030", text_ = "#f0e6d4", gold = 0.15, leather = False }

        4 ->
            { bg = "#6a2020", text_ = "#f0e4d0", gold = 0.25, leather = False }

        _ ->
            { bg = "#4a4a30", text_ = "#e8dcc8", gold = 0.15, leather = False }


{-| Texture URL for a book based on its texture type and title hash.
-}
textureUrl : SpineTexture -> String -> String
textureUrl texture titleStr =
    let
        idx =
            colorIndex titleStr

        subIdx =
            modBy 3 idx

        variant =
            case ( texture, subIdx ) of
                ( Leather, 0 ) ->
                    "spine-leather-burgundy"

                ( Leather, 1 ) ->
                    "spine-leather-green"

                ( Leather, _ ) ->
                    "spine-leather-navy"

                ( Cloth, 0 ) ->
                    "spine-cloth-brown"

                ( Cloth, 1 ) ->
                    "spine-cloth-red"

                ( Cloth, _ ) ->
                    "spine-cloth-olive"
    in
    "url('/textures/" ++ variant ++ ".png')"


{-| Render a complete book element with 3D spine, top, and cover.
This produces the full `.book >.book__spine +.book__top +.book__cover`
structure matching the reference mockup.
-}
book :
    { pageCount : Int
    , wearLevel : WearLevel
    , texture : SpineTexture
    , title : String
    , author : String
    , coverImageUrl : Maybe String
    , hidden : Bool
    , hasWriting : Bool
    }
    -> Html msg
book config =
    let
        widthPx =
            spineWidth config.pageCount

        heightPx =
            spineHeight config.pageCount

        idx =
            colorIndex config.title

        tex =
            textureData idx

        isGold =
            useGold config.title tex.gold

        titleColor =
            if isGold then
                "#d4af37"

            else
                tex.text_

        titleShadow =
            if isGold then
                "0 0 3px rgba(212,175,55,0.2), 0 1px 2px rgba(0,0,0,0.6)"

            else
                "0 1px 2px rgba(0,0,0,0.6)"

        authorColor =
            if isGold then
                "rgba(212,175,55,0.45)"

            else
                tex.text_

        isLeather =
            case config.texture of
                Leather ->
                    True

                Cloth ->
                    False

        bands =
            if isLeather then
                [ div [ class "book__band", style "top" "16%" ] []
                , div [ class "book__band", style "bottom" "16%" ] []
                ]

            else
                []

        coverBg =
            case config.coverImageUrl of
                Just url ->
                    "url('" ++ String.replace "'" "" url ++ "')"

                Nothing ->
                    "none"

        bgImage =
            textureUrl config.texture config.title
    in
    let
        depth =
            160

        halfDepth =
            depth // 2

        topTransform =
            "rotateX(90deg) translateZ("
                ++ String.fromInt halfDepth
                ++ "px) translateY(-"
                ++ String.fromInt halfDepth
                ++ "px)"

        coverTransform =
            "rotateY(90deg)"
    in
    let
        wearSuffix =
            case config.wearLevel of
                Pristine ->
                    ""

                Softened ->
                    ", well-loved"

        notesSuffix =
            if config.hasWriting then
                ", with your notes"

            else
                ""

        hiddenSuffix =
            if config.hidden then
                ", hidden (only visible to you)"

            else
                ""

        ariaLabel =
            "Book: "
                ++ config.title
                ++ " by "
                ++ config.author
                ++ ", "
                ++ String.fromInt config.pageCount
                ++ " pages"
                ++ wearSuffix
                ++ notesSuffix
                ++ hiddenSuffix

        wrapperClass =
            case ( config.hidden, config.wearLevel ) of
                ( True, Softened ) ->
                    class "book book--hidden book--softened"

                ( True, Pristine ) ->
                    class "book book--hidden"

                ( False, Softened ) ->
                    class "book book--softened"

                ( False, Pristine ) ->
                    class "book"

        lockEls =
            if config.hidden then
                [ div [ class "book__lock", attribute "aria-hidden" "true" ] [ text "🔒" ] ]

            else
                []

        ribbonEls =
            if config.hasWriting then
                [ div [ class "book__ribbon", attribute "aria-hidden" "true" ] [] ]

            else
                []
    in
    div
        [ wrapperClass
        , testId "book-spine"
        , style "width" (String.fromInt widthPx ++ "px")
        , style "height" (String.fromInt heightPx ++ "px")
        , style "transform-style" "preserve-3d"
        , title (config.title ++ " — " ++ config.author)
        , attribute "aria-label" ariaLabel
        ]
        ([ div
            [ class "book__face book__spine"
            , style "background-color" tex.bg
            , style "background-image" bgImage
            ]
            (bands
                ++ [ span
                        [ class "book__title"
                        , style "color" titleColor
                        , style "text-shadow" titleShadow
                        ]
                        [ text config.title ]
                   , span
                        [ class "book__author"
                        , style "color" authorColor
                        ]
                        [ text config.author ]
                   ]
            )
         , div
            [ class "book__face book__top"
            , style "width" (String.fromInt widthPx ++ "px")
            , style "height" (String.fromInt depth ++ "px")
            , style "transform" topTransform
            , style "top" "0"
            , style "left" "0"
            ]
            []
         , div
            [ class "book__face book__cover"
            , style "width" (String.fromInt depth ++ "px")
            , style "height" (String.fromInt heightPx ++ "px")
            , style "background-image"
                (if coverBg == "none" then
                    bgImage

                 else
                    coverBg
                )
            , style "background-color" tex.bg
            , style "transform" coverTransform
            , style "transform-origin" "left center"
            , style "top" "0"
            , style "left" (String.fromInt widthPx ++ "px")
            ]
            []
         ]
            ++ ribbonEls
            ++ lockEls
        )
