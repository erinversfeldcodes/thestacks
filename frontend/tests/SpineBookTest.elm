module SpineBookTest exposing (suite)

{-| Tests for the book rendering in Components.Spine.

These tests validate: each book element has three face divs (spine, top, cover),
title/author text, leather band elements, spine width based on the formula
(min 35px, max 55px via pages/12), and a background-image referencing a texture file path.

-}

import Components.Spine exposing (SpineTexture(..), WearLevel(..), book, spineHeight, spineLean, spineWidth, textureUrl)
import Expect
import Html
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector


suite : Test
suite =
    describe "Components.Spine book structure"
        [ spineWidthNewFormula
        , spineHeightBoundary
        , spineLeanBoundary
        , bookHasPreserve3d
        , bookHasThreeFaces
        , bookSpineHasTitleAndAuthor
        , leatherBookHasBands
        , clothBookHasNoBands
        , spineHasTextureBackgroundImage
        ]


{-| The redesigned spine width formula: max(35, min(55, round(pages / 12)))
-}
spineWidthNewFormula : Test
spineWidthNewFormula =
    describe "Spine width uses new formula: max(35, min(55, round(pages/12)))"
        [ test "minimum width is 35px for small page counts" <|
            \_ ->
                spineWidth 100
                    |> Expect.equal 35
        , test "420 pages gives 35px (boundary)" <|
            \_ ->
                spineWidth 420
                    |> Expect.equal 35
        , test "500 pages gives 42px" <|
            \_ ->
                spineWidth 500
                    |> Expect.equal 42
        , test "600 pages gives 50px" <|
            \_ ->
                spineWidth 600
                    |> Expect.equal 50
        , test "maximum width is 55px for very large books" <|
            \_ ->
                spineWidth 9999
                    |> Expect.equal 55
        ]


{-| spineHeight returns a height based on page count with base 238, capped growth, and jitter.
-}
spineHeightBoundary : Test
spineHeightBoundary =
    describe "Spine height boundary conditions"
        [ test "0 pages gives base height (238) plus jitter" <|
            \_ ->
                spineHeight 0
                    |> Expect.atLeast 238
        , test "0 pages does not exceed base + max jitter (238 + 7)" <|
            \_ ->
                spineHeight 0
                    |> Expect.atMost 245
        , test "750+ pages gives near-max growth (238 + 48 = 286) plus jitter" <|
            \_ ->
                spineHeight 750
                    |> Expect.atLeast 286
        , test "750+ pages does not exceed 286 + 7" <|
            \_ ->
                spineHeight 750
                    |> Expect.atMost 293
        , test "very large page count still caps growth at 48" <|
            \_ ->
                spineHeight 10000
                    |> Expect.atLeast 286
        ]


{-| spineLean returns a small float angle derived from title hash.
The formula is ((hash(title) % 16) - 8) / 10 so range is [-0.8, 0.7].
-}
spineLeanBoundary : Test
spineLeanBoundary =
    describe "Spine lean boundary conditions"
        [ test "lean is within expected range lower bound" <|
            \_ ->
                spineLean "Test Title"
                    |> Expect.atLeast -0.8
        , test "lean is within expected range upper bound" <|
            \_ ->
                spineLean "Test Title"
                    |> Expect.atMost 0.7
        , test "same title produces same lean (deterministic)" <|
            \_ ->
                spineLean "Moby Dick"
                    |> Expect.within (Expect.Absolute 0.001) (spineLean "Moby Dick")
        , test "empty string produces valid lean" <|
            \_ ->
                spineLean ""
                    |> Expect.atLeast -0.8
        ]


sampleBook : Html.Html msg
sampleBook =
    book
        { pageCount = 400
        , wearLevel = Pristine
        , texture = Leather
        , title = "Moby Dick"
        , author = "Herman Melville"
        , coverImageUrl = Nothing
        , hidden = False
        }


sampleClothBook : Html.Html msg
sampleClothBook =
    book
        { pageCount = 300
        , wearLevel = Softened
        , texture = Cloth
        , title = "Jane Eyre"
        , author = "Charlotte Bronte"
        , coverImageUrl = Nothing
        , hidden = False
        }


{-| The book container must have transform-style: preserve-3d for 3D effect.
-}
bookHasPreserve3d : Test
bookHasPreserve3d =
    test "book container has transform-style preserve-3d" <|
        \_ ->
            sampleBook
                |> Query.fromHtml
                |> Query.has
                    [ Selector.class "book"
                    , Selector.style "transform-style" "preserve-3d"
                    ]


{-| Each book must contain three face divs: .book\_\_spine, .book**top, .book**cover
-}
bookHasThreeFaces : Test
bookHasThreeFaces =
    describe "book contains three face divs"
        [ test "has .book__spine" <|
            \_ ->
                sampleBook
                    |> Query.fromHtml
                    |> Query.has [ Selector.class "book__spine" ]
        , test "has .book__top" <|
            \_ ->
                sampleBook
                    |> Query.fromHtml
                    |> Query.has [ Selector.class "book__top" ]
        , test "has .book__cover" <|
            \_ ->
                sampleBook
                    |> Query.fromHtml
                    |> Query.has [ Selector.class "book__cover" ]
        ]


{-| Spine face must contain .book\_\_title and .book\_\_author with correct text.
-}
bookSpineHasTitleAndAuthor : Test
bookSpineHasTitleAndAuthor =
    describe "spine has title and author text"
        [ test "spine has .book__title with book title" <|
            \_ ->
                sampleBook
                    |> Query.fromHtml
                    |> Query.find [ Selector.class "book__spine" ]
                    |> Query.find [ Selector.class "book__title" ]
                    |> Query.has [ Selector.text "Moby Dick" ]
        , test "spine has .book__author with author name" <|
            \_ ->
                sampleBook
                    |> Query.fromHtml
                    |> Query.find [ Selector.class "book__spine" ]
                    |> Query.find [ Selector.class "book__author" ]
                    |> Query.has [ Selector.text "Herman Melville" ]
        ]


{-| Leather-textured books must have .book\_\_band elements.
-}
leatherBookHasBands : Test
leatherBookHasBands =
    test "leather book has .book__band elements" <|
        \_ ->
            sampleBook
                |> Query.fromHtml
                |> Query.findAll [ Selector.class "book__band" ]
                |> Query.count (Expect.atLeast 1)


{-| Cloth-textured books must NOT have .book\_\_band elements.
-}
clothBookHasNoBands : Test
clothBookHasNoBands =
    test "cloth book has no .book__band elements" <|
        \_ ->
            sampleClothBook
                |> Query.fromHtml
                |> Query.findAll [ Selector.class "book__band" ]
                |> Query.count (Expect.equal 0)


{-| Spine background-image must reference a texture file path, not just a flat color.
-}
spineHasTextureBackgroundImage : Test
spineHasTextureBackgroundImage =
    test "spine has a background-image style referencing a texture" <|
        \_ ->
            sampleBook
                |> Query.fromHtml
                |> Query.find [ Selector.class "book__spine" ]
                |> Query.has [ Selector.style "background-image" (textureUrl Leather "Moby Dick") ]
