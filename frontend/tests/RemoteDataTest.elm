module RemoteDataTest exposing (suite)

import Expect
import Test exposing (Test, describe, test)
import Types.RemoteData exposing (RemoteData(..), fromResult, map, withDefault)


suite : Test
suite =
    describe "RemoteData"
        [ describe "map"
            [ test "maps Success value" <|
                \_ ->
                    map (\x -> x + 1) (Success 5)
                        |> Expect.equal (Success 6)
            , test "leaves NotAsked unchanged" <|
                \_ ->
                    map (\x -> x + 1) NotAsked
                        |> Expect.equal NotAsked
            , test "leaves Loading unchanged" <|
                \_ ->
                    map (\x -> x + 1) Loading
                        |> Expect.equal Loading
            , test "leaves Failure unchanged" <|
                \_ ->
                    map (\x -> x + 1) (Failure "error")
                        |> Expect.equal (Failure "error")
            ]
        , describe "withDefault"
            [ test "returns value for Success" <|
                \_ ->
                    withDefault 0 (Success 42)
                        |> Expect.equal 42
            , test "returns default for NotAsked" <|
                \_ ->
                    withDefault 0 NotAsked
                        |> Expect.equal 0
            , test "returns default for Loading" <|
                \_ ->
                    withDefault 0 Loading
                        |> Expect.equal 0
            , test "returns default for Failure" <|
                \_ ->
                    withDefault 0 (Failure "err")
                        |> Expect.equal 0
            ]
        , describe "fromResult"
            [ test "converts Ok to Success" <|
                \_ ->
                    fromResult (Ok 42)
                        |> Expect.equal (Success 42)
            , test "converts Err to Failure" <|
                \_ ->
                    fromResult (Err "oops")
                        |> Expect.equal (Failure "oops")
            ]
        ]
