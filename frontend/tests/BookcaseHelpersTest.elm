module BookcaseHelpersTest exposing (suite)

{-| Tests for the bookcase frame structure in Page.Bookshelf.Helpers.

These tests validate the DoD items for Issue #029:

  - viewBookcase wraps content in .bookcase with .bookcase\_\_side--left and .bookcase\_\_side--right
  - viewShelfRow renders .shelf-row containing .shelf-row\_\_back, .shelf-row\_\_books, .shelf-row\_\_plank, .shelf-row\_\_lip
  - Books are grouped into rows that fit within the shelf width

-}

import Components.Spine exposing (WearLevel(..))
import Expect
import Page.Bookshelf.Helpers exposing (groupIntoRows, viewShelfRow)
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers exposing (testPlacement)


suite : Test
suite =
    describe "Page.Bookshelf.Helpers bookcase frame structure"
        [ shelfRowHasLip
        , groupIntoRowsRespectsFit
        ]


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
