module SpineTest exposing (suite)

import Components.Spine exposing (spineWidth)
import Expect
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Spine width calculation (mockup formula: max(35, min(55, round(pages/12))))"
        [ test "minimum width is 35px for 0 pages" <|
            \_ ->
                spineWidth 0
                    |> Expect.equal 35
        , test "minimum width is 35px for small books" <|
            \_ ->
                spineWidth 200
                    |> Expect.equal 35
        , test "360 pages gives 35px (below minimum)" <|
            \_ ->
                spineWidth 360
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
        , test "maximum width is 55px for large books" <|
            \_ ->
                spineWidth 700
                    |> Expect.equal 55
        , test "maximum width is 55px for very large page count" <|
            \_ ->
                spineWidth 9999
                    |> Expect.equal 55
        , test "480 pages gives 40px (round(480/12))" <|
            \_ ->
                spineWidth 480
                    |> Expect.equal 40
        , test "540 pages gives 45px (round(540/12))" <|
            \_ ->
                spineWidth 540
                    |> Expect.equal 45
        , test "660 pages gives 55px (the exact ceiling: round(660/12))" <|
            \_ ->
                spineWidth 660
                    |> Expect.equal 55
        , test "1000 pages clamps to 55px (round(1000/12) = 83, over the ceiling)" <|
            \_ ->
                spineWidth 1000
                    |> Expect.equal 55
        , test "width is monotonic through the sloped mid-range (480 < 540)" <|
            \_ ->
                spineWidth 480
                    |> Expect.lessThan (spineWidth 540)
        ]
