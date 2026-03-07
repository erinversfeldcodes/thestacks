module SpineTest exposing (suite)

import Components.Spine exposing (spineWidth)
import Expect
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Spine width calculation"
        [ test "minimum width is 8px for 0 pages" <|
            \_ ->
                spineWidth 0
                    |> Expect.equal 8
        , test "minimum width is 8px for 79 pages" <|
            \_ ->
                spineWidth 79
                    |> Expect.equal 8
        , test "100 pages gives 10px" <|
            \_ ->
                spineWidth 100
                    |> Expect.equal 10
        , test "200 pages gives 20px" <|
            \_ ->
                spineWidth 200
                    |> Expect.equal 20
        , test "300 pages gives 30px" <|
            \_ ->
                spineWidth 300
                    |> Expect.equal 30
        , test "400 pages gives 40px" <|
            \_ ->
                spineWidth 400
                    |> Expect.equal 40
        , test "maximum width is 40px for 1000 pages" <|
            \_ ->
                spineWidth 1000
                    |> Expect.equal 40
        , test "maximum width is 40px for very large page count" <|
            \_ ->
                spineWidth 9999
                    |> Expect.equal 40
        ]
