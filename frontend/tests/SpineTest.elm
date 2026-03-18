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
        ]
