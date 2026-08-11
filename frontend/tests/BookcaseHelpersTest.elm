module BookcaseHelpersTest exposing (suite)

{-| Tests for the bookcase frame structure in Page.Bookshelf.Helpers.

These tests validate the DoD items for Issue #029:

  - viewBookcase wraps content in .bookcase with .bookcase\_\_side--left and .bookcase\_\_side--right
  - viewShelfRow renders .shelf-row containing .shelf-row\_\_back, .shelf-row\_\_books, .shelf-row\_\_plank, .shelf-row\_\_lip
  - Books are grouped into rows that fit within the shelf width

Issue #112 punch #14 adds the cases that matter in production: `groupIntoRows`
at the real bookcase inner width (990px) rather than a toy `maxWidth`, and the
`minShelfRows 4` padding that keeps a sparse bookcase looking like furniture.

-}

import Components.Spine exposing (WearLevel(..))
import Expect
import Html
import Html.Attributes
import Page.Bookshelf.Helpers exposing (groupIntoRows, minShelfRows, viewShelfRow)
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers exposing (libraryProgram, placementWithPages, simulateBookshelfResponse, testBook, testPlacement)
import Types.Placement exposing (Placement)


suite : Test
suite =
    describe "Page.Bookshelf.Helpers bookcase frame structure"
        [ shelfRowHasLip
        , groupIntoRowsRespectsFit
        , groupIntoRowsAtProductionWidth
        , minShelfRowsPadding
        , productionWidthDrivenThroughThePage
        , noPageCountFallsBackToMinimumWidth
        , shelfLabelPluralisation
        ]


{-| The shelf's `role="list"` container carries an `aria-label` a screen reader
reads verbatim, so its grammar is heard, not just seen (#318 TR-6). A one-book
shelf must say "1 book", not "1 books"; two must say "2 books". Both directions
are asserted so the test fails on the old naive `String.fromInt n ++ " books"`.
-}
shelfLabelPluralisation : Test
shelfLabelPluralisation =
    describe "viewShelfRow aria-label pluralises the book count"
        [ test "one_book_is_singular: a shelf of one book says '1 book'" <|
            \_ ->
                viewShelfRow Softened [ testPlacement ]
                    |> Query.fromHtml
                    |> Query.find [ Selector.class "shelf-row__books" ]
                    |> Query.has [ shelfAriaLabel "Shelf — 1 book" ]
        , test "two_books_are_plural: a shelf of two books says '2 books'" <|
            \_ ->
                viewShelfRow Softened [ testPlacement, testPlacement ]
                    |> Query.fromHtml
                    |> Query.find [ Selector.class "shelf-row__books" ]
                    |> Query.has [ shelfAriaLabel "Shelf — 2 books" ]
        ]


shelfAriaLabel : String -> Selector.Selector
shelfAriaLabel value =
    Selector.attribute (Html.Attributes.attribute "aria-label" value)


{-| A shelf row must include a .shelf-row\_\_lip element after the plank.
-}
shelfRowHasLip : Test
shelfRowHasLip =
    test "viewShelfRow renders .shelf-row__lip element" <|
        \_ ->
            viewShelfRow Softened [ testPlacement ]
                |> Query.fromHtml
                |> Query.has [ Selector.class "shelf-row__lip" ]


{-| groupIntoRows should break placements into rows that fit within maxWidth.
A placement with 400 pages gives spineWidth ~35px + 2px gap = 37px.
With maxWidth=80, two should fit in one row but three should split.
-}
groupIntoRowsRespectsFit : Test
groupIntoRowsRespectsFit =
    describe "groupIntoRows fits books within shelf width"
        [ test "single book fits in one row" <|
            \_ ->
                groupIntoRows 80 [ testPlacement ]
                    |> List.length
                    |> Expect.equal 1
        , test "many books split across multiple rows" <|
            \_ ->
                let
                    placements =
                        List.repeat 10 testPlacement
                in
                groupIntoRows 80 placements
                    |> List.length
                    |> Expect.greaterThan 1
        ]


{-| The bookcase inner width in production is 990px (`Page.Bookshelf`'s
`bookcaseInnerWidth`). Packing is by `spineWidth pageCount + 2`:

  - a 371-page book is the `spineWidth` floor — 35px + 2 = 37px, so 26 fit
    (962px) and the 27th would reach 999px;
  - a 660-page book is the `spineWidth` ceiling — 55px + 2 = 57px, so 17 fit
    (969px) and the 18th would reach 1026px.

These are the exact row boundaries, not a "more than one row" smoke check.

-}
groupIntoRowsAtProductionWidth : Test
groupIntoRowsAtProductionWidth =
    describe "groupIntoRows 990 (production bookcase inner width)"
        [ test "thin_spines_fill_one_row: 26 minimum-width books fill exactly one row" <|
            \_ ->
                groupIntoRows 990 (thinBooks 26)
                    |> List.map List.length
                    |> Expect.equal [ 26 ]
        , test "thin_spines_overflow_at_27: the 27th minimum-width book starts a second row" <|
            \_ ->
                groupIntoRows 990 (thinBooks 27)
                    |> List.map List.length
                    |> Expect.equal [ 26, 1 ]
        , test "thick_spines_fill_one_row: 17 maximum-width books fill exactly one row" <|
            \_ ->
                groupIntoRows 990 (thickBooks 17)
                    |> List.map List.length
                    |> Expect.equal [ 17 ]
        , test "thick_spines_overflow_at_18: the 18th maximum-width book starts a second row" <|
            \_ ->
                groupIntoRows 990 (thickBooks 18)
                    |> List.map List.length
                    |> Expect.equal [ 17, 1 ]
        , test "mixed_spines_pack_by_width_not_count: thick books fill a row sooner than thin ones" <|
            \_ ->
                let
                    thinRows =
                        List.length (groupIntoRows 990 (thinBooks 20))

                    thickRows =
                        List.length (groupIntoRows 990 (thickBooks 20))
                in
                ( thinRows, thickRows )
                    |> Expect.equal ( 1, 2 )
        , test "no_books_no_rows: an empty bookshelf produces no rows at all" <|
            \_ ->
                groupIntoRows 990 []
                    |> Expect.equal []
        ]


{-| `minShelfRows 4` is what stops a nearly-empty bookcase rendering as a
single floating plank: short bookshelves are padded up to four rows, and a
bookshelf that already exceeds four is left alone.
-}
minShelfRowsPadding : Test
minShelfRowsPadding =
    describe "minShelfRows 4 pads a short bookcase"
        [ test "empty_pads_to_four: no rows are padded up to four" <|
            \_ ->
                minShelfRows 4 []
                    |> List.length
                    |> Expect.equal 4
        , test "one_row_pads_to_four: a single row is padded up to four" <|
            \_ ->
                minShelfRows 4 [ Html.text "row" ]
                    |> List.length
                    |> Expect.equal 4
        , test "four_rows_unpadded: exactly four rows are left alone" <|
            \_ ->
                minShelfRows 4 (List.repeat 4 (Html.text "row"))
                    |> List.length
                    |> Expect.equal 4
        , test "tall_bookcase_not_truncated: six rows stay six — padding never removes rows" <|
            \_ ->
                minShelfRows 4 (List.repeat 6 (Html.text "row"))
                    |> List.length
                    |> Expect.equal 6
        ]


{-| The width above is only meaningful if it is the width the page actually
uses. Driving 27 minimum-width books through the real bookshelf pins
`Page.Bookshelf`'s (private) `bookcaseInnerWidth` to 990: the first rendered
shelf row must hold 26 books and the second exactly 1.
-}
productionWidthDrivenThroughThePage : Test
productionWidthDrivenThroughThePage =
    test "page_packs_rows_at_production_width: the rendered bookcase breaks after 26 minimum-width books" <|
        \() ->
            ProgramTest.start () (libraryProgram (Just "test-token"))
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateBookshelfResponse (thinBooks 27))
                |> ProgramTest.ensureView
                    (Query.findAll [ Selector.class "shelf-row__books" ]
                        >> Query.index 0
                        >> Query.findAll [ Selector.class "book-button" ]
                        >> Query.count (Expect.equal 26)
                    )
                |> ProgramTest.ensureView
                    (Query.findAll [ Selector.class "shelf-row__books" ]
                        >> Query.index 1
                        >> Query.findAll [ Selector.class "book-button" ]
                        >> Query.count (Expect.equal 1)
                    )
                |> ProgramTest.expectView
                    (Query.findAll [ Selector.class "shelf-row" ]
                        >> Query.count (Expect.equal 4)
                    )


{-| When a placement's book has no page count, `viewShelfRow` (via the private
`viewSpine`) feeds `Maybe.withDefault 200 (bookPageCount bk)` into
`Components.Spine.spineWidth`, and `spineWidth 200` clamps to the 35px floor.
This pins that fallback at the render level: a missing page count must still
produce a real, minimum-width spine — not a zero-width or absent one. Both the
"book present but page-count absent" and the "no book at all" branches of
`viewSpine` route through the same 200-default, so both render at 35px.
-}
noPageCountFallsBackToMinimumWidth : Test
noPageCountFallsBackToMinimumWidth =
    describe "a book with no page count falls back to the 35px minimum spine width"
        [ test "primary edition without a page_count renders at 35px" <|
            \_ ->
                viewShelfRow Softened [ noPagePlacement ]
                    |> Query.fromHtml
                    |> Query.find [ Selector.class "book" ]
                    |> Query.has [ Selector.style "width" "35px" ]
        , test "a placement with no book at all still renders a 35px spine" <|
            \_ ->
                viewShelfRow Softened [ booklessPlacement ]
                    |> Query.fromHtml
                    |> Query.find [ Selector.class "book" ]
                    |> Query.has [ Selector.style "width" "35px" ]
        ]


{-| A placement whose book has neither editions nor a primary edition, so
`bookPageCount` returns `Nothing` and the render falls back to the 200-default.
-}
noPagePlacement : Placement
noPagePlacement =
    { testPlacement
        | id = "placement-nopage"
        , book = Just { testBook | editions = [], primaryEdition = Nothing }
    }


{-| A placement with no book at all — the `Nothing` branch of `viewSpine`.
-}
booklessPlacement : Placement
booklessPlacement =
    { testPlacement | id = "placement-bookless", book = Nothing }


{-| Books at the `spineWidth` floor: 35px + 2px gap = 37px each.
-}
thinBooks : Int -> List Placement
thinBooks n =
    List.range 1 n
        |> List.map (\i -> placementWithPages ("thin-" ++ String.fromInt i) 371)


{-| Books at the `spineWidth` ceiling: 55px + 2px gap = 57px each.
-}
thickBooks : Int -> List Placement
thickBooks n =
    List.range 1 n
        |> List.map (\i -> placementWithPages ("thick-" ++ String.fromInt i) 660)
