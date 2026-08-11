module GridNavTest exposing (suite)

{-| The roving-tabindex navigation state machine, as pure decisions over
packed rows. The fixture grid has ragged rows at known centers;
vertical moves are NEAREST-X (owner decision), horizontal moves clamp
at row ends, and focus follows the roving index. Pure decision tests —
DOM focus is the browser's job.
-}

import Expect
import Json.Decode as Decode
import Page.Bookshelf.GridNav as GridNav exposing (Key(..))
import Test exposing (Test, describe, test)


grid : List (List ( String, Int ))
grid =
    [ [ ( "A", 100 ), ( "B", 50 ), ( "C", 200 ) ]
    , [ ( "D", 300 ), ( "E", 40 ) ]
    , [ ( "F", 90 ) ]
    ]


suite : Test
suite =
    describe "GridNav"
        [ describe "horizontal moves stay in the row"
            [ test "ArrowRight moves to the next spine" <|
                \_ -> GridNav.nextFocus ArrowRight "A" grid |> Expect.equal (Just "B")
            , test "ArrowLeft moves to the previous spine" <|
                \_ -> GridNav.nextFocus ArrowLeft "B" grid |> Expect.equal (Just "A")
            , test "ArrowRight at the row end stays put" <|
                \_ -> GridNav.nextFocus ArrowRight "C" grid |> Expect.equal Nothing
            , test "ArrowLeft at the row start stays put" <|
                \_ -> GridNav.nextFocus ArrowLeft "A" grid |> Expect.equal Nothing
            , test "Home jumps to the row start" <|
                \_ -> GridNav.nextFocus Home "C" grid |> Expect.equal (Just "A")
            , test "End jumps to the row end" <|
                \_ -> GridNav.nextFocus End "A" grid |> Expect.equal (Just "C")
            ]
        , describe "vertical moves are nearest-x, not same-index"
            [ test "down from A (center 50) lands on D (150), not E (320)" <|
                \_ -> GridNav.nextFocus ArrowDown "A" grid |> Expect.equal (Just "D")
            , test "down from C (center 250) lands on E (320) — an index model would say D" <|
                \_ -> GridNav.nextFocus ArrowDown "C" grid |> Expect.equal (Just "E")
            , test "down from D lands on the only spine below" <|
                \_ -> GridNav.nextFocus ArrowDown "D" grid |> Expect.equal (Just "F")
            , test "up from F (center 45) lands on D (150), not E (320)" <|
                \_ -> GridNav.nextFocus ArrowUp "F" grid |> Expect.equal (Just "D")
            , test "up from the top row stays put" <|
                \_ -> GridNav.nextFocus ArrowUp "A" grid |> Expect.equal Nothing
            , test "down from the bottom row stays put" <|
                \_ -> GridNav.nextFocus ArrowDown "F" grid |> Expect.equal Nothing
            , test "an exact x tie goes to the earlier spine, so ↑↓ does not drift" <|
                \_ ->
                    GridNav.nextFocus ArrowDown
                        "X"
                        [ [ ( "X", 200 ) ]
                        , [ ( "G", 100 ), ( "H", 100 ) ]
                        ]
                        |> Expect.equal (Just "G")
            ]
        , describe "edge inputs"
            [ test "an id not on the grid moves nothing" <|
                \_ -> GridNav.nextFocus ArrowRight "ghost" grid |> Expect.equal Nothing
            , test "an empty grid moves nothing" <|
                \_ -> GridNav.nextFocus ArrowDown "A" [] |> Expect.equal Nothing
            ]
        , describe "keyDecoder claims exactly the six navigation keys"
            (let
                decodes key expected =
                    test ("decodes " ++ key) <|
                        \_ ->
                            Decode.decodeString GridNav.keyDecoder
                                ("{\"key\":\"" ++ key ++ "\"}")
                                |> Expect.equal (Ok expected)

                refuses key =
                    test ("refuses " ++ key ++ " — Tab must tab, Enter must click") <|
                        \_ ->
                            Decode.decodeString GridNav.keyDecoder
                                ("{\"key\":\"" ++ key ++ "\"}")
                                |> Result.toMaybe
                                |> Expect.equal Nothing
             in
             [ decodes "ArrowLeft" ArrowLeft
             , decodes "ArrowRight" ArrowRight
             , decodes "ArrowUp" ArrowUp
             , decodes "ArrowDown" ArrowDown
             , decodes "Home" Home
             , decodes "End" End
             , refuses "Enter"
             , refuses " "
             , refuses "Tab"
             , refuses "Escape"
             ]
            )
        ]
