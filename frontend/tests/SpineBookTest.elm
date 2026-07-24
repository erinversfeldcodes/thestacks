module SpineBookTest exposing (suite)

{-| Tests for the book rendering in Components.Spine.

These tests validate: each book element has three face divs (spine, top, cover),
title/author text, leather band elements, spine width based on the formula
(min 35px, max 55px via pages/12), and a background-image referencing a texture file path.

-}

import Components.Spine exposing (SpineTexture(..), WearLevel(..), book, spineHeight, spineLean, spineWidth, textureUrl)
import Expect
import Html
import Html.Attributes
import Page.Bookshelf as Bookshelf
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers exposing (namedPlacement, readingPileProgram, simulateBookshelfResponse)


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
        , wearSuffixInAriaLabel
        , softenedBookHasWearClass
        , perShelfWearConfig
        , readingPileSpineIsSoftened
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


{-| A hidden, Softened book: exercises both aria suffixes together.
-}
softenedHiddenBook : Html.Html msg
softenedHiddenBook =
    book
        { pageCount = 400
        , wearLevel = Softened
        , texture = Leather
        , title = "The Secret History"
        , author = "Donna Tartt"
        , coverImageUrl = Nothing
        , hidden = True
        }


hasAriaLabel : String -> Query.Single msg -> Expect.Expectation
hasAriaLabel expected single =
    single
        |> Query.has
            [ Selector.attribute (Html.Attributes.attribute "aria-label" expected) ]


{-| The wear level shows up in the aria-label as a ", well-loved" suffix, and
_only_ for `Softened` — `Pristine` books carry no suffix at all. The suffix must
also compose with the owner-only "hidden" suffix in a fixed order (wear first,
then hidden), so a screen-reader hears "…, well-loved, hidden (only visible to
you)" rather than the reverse. Asserting the exact whole aria-label pins both
the presence/absence of the wear suffix and its position.
-}
wearSuffixInAriaLabel : Test
wearSuffixInAriaLabel =
    describe "wear level drives the aria-label suffix"
        [ test "Pristine book has no wear suffix" <|
            \_ ->
                sampleBook
                    |> Query.fromHtml
                    |> hasAriaLabel "Book: Moby Dick by Herman Melville, 400 pages"
        , test "Softened book ends with ', well-loved'" <|
            \_ ->
                sampleClothBook
                    |> Query.fromHtml
                    |> hasAriaLabel "Book: Jane Eyre by Charlotte Bronte, 300 pages, well-loved"
        , test "Softened + hidden composes both suffixes in order (wear then hidden)" <|
            \_ ->
                softenedHiddenBook
                    |> Query.fromHtml
                    |> hasAriaLabel "Book: The Secret History by Donna Tartt, 400 pages, well-loved, hidden (only visible to you)"
        ]


{-| Wear also drives a visible CSS hook: a `Softened` book carries the
`book--softened` class (the muted, worn treatment in main.css), a `Pristine` book
does not, and the class composes with the base `book` class and the owner-only
`book--hidden` class (Issue #288). Asserting the class here pins the Elm side of
the visual distinction the Playwright computed-style test proves live.
-}
softenedBookHasWearClass : Test
softenedBookHasWearClass =
    describe "wear level drives the book--softened class"
        [ test "Softened book has the book--softened class" <|
            \_ ->
                sampleClothBook
                    |> Query.fromHtml
                    |> Query.has [ Selector.class "book", Selector.class "book--softened" ]
        , test "Pristine book has no book--softened class" <|
            \_ ->
                sampleBook
                    |> Query.fromHtml
                    |> Query.hasNot [ Selector.class "book--softened" ]
        , test "Softened + hidden composes book, book--hidden and book--softened" <|
            \_ ->
                softenedHiddenBook
                    |> Query.fromHtml
                    |> Query.has
                        [ Selector.class "book"
                        , Selector.class "book--hidden"
                        , Selector.class "book--softened"
                        ]
        ]


{-| Each bookshelf pins its own static wear level in its `Config`. Library books
render as `Softened` (a read shelf), while the Antilibrary and Wish List — books
you own-but-haven't-read and books you want — stay `Pristine`. These assert the
config records directly, the honest surface for a static, per-shelf setting.
-}
perShelfWearConfig : Test
perShelfWearConfig =
    describe "per-bookshelf wear configuration"
        [ test "library is Softened" <|
            \_ ->
                Bookshelf.libraryConfig.wearLevel
                    |> Expect.equal Softened
        , test "antilibrary is Pristine" <|
            \_ ->
                Bookshelf.antiLibraryConfig.wearLevel
                    |> Expect.equal Pristine
        , test "wish list is Pristine" <|
            \_ ->
                Bookshelf.wishListConfig.wearLevel
                    |> Expect.equal Pristine
        ]


{-| The Reading Pile has no `Config` record — it hardcodes `Softened` wear inline
in its piled-book render. The honest surface there is the rendered aria-label:
a book driven into the pile must announce ", well-loved". (`namedPlacement`
wraps the shared `testBook`: 371 pages, "Charles Duhigg", not hidden.)
-}
readingPileSpineIsSoftened : Test
readingPileSpineIsSoftened =
    test "reading pile spines render Softened wear (', well-loved')" <|
        \() ->
            ProgramTest.start () (readingPileProgram (Just "test-token"))
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/reading_pile"
                    (simulateBookshelfResponse [ namedPlacement "book-rp" "Reading Now" ])
                |> ProgramTest.expectViewHas
                    [ Selector.attribute
                        (Html.Attributes.attribute "aria-label"
                            "Book: Reading Now by Charles Duhigg, 371 pages, well-loved"
                        )
                    ]
