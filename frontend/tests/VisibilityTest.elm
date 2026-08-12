module VisibilityTest exposing (suite)

{-| Unit tests for Types.Visibility — the placement/shelf visibility ranking
and the client-side ceiling rule that mirrors the server-side 422
(`validate_visibility_ceiling`, ranking public(0) < platform(1) < owner(2)).
-}

import Expect
import Test exposing (Test, describe, test)
import Types.Visibility as V exposing (Visibility(..))


suite : Test
suite =
    describe "Types.Visibility"
        [ roundTrip
        , ranking
        , exceedsCeilingRule
        , placementOptionsForCeiling
        , ceilingHelperTextRule
        ]


roundTrip : Test
roundTrip =
    describe "fromString / toString round-trip"
        [ test "public" <|
            \_ -> V.fromString "public" |> Expect.equal (Just Public)
        , test "platform" <|
            \_ -> V.fromString "platform" |> Expect.equal (Just Platform)
        , test "owner" <|
            \_ -> V.fromString "owner" |> Expect.equal (Just Owner)
        , test "unknown -> Nothing" <|
            \_ -> V.fromString "nonsense" |> Expect.equal Nothing
        , test "toString is the inverse for owner" <|
            \_ -> V.toString Owner |> Expect.equal "owner"
        , test "toString is the inverse for public" <|
            \_ -> V.toString Public |> Expect.equal "public"
        ]


ranking : Test
ranking =
    describe "rank orders by exposure: owner < group < platform < public"
        [ test "owner is least exposed" <|
            \_ -> V.rank Owner |> Expect.equal 0
        , test "group sits above owner" <|
            \_ -> V.rank Group |> Expect.equal 1
        , test "platform (Members) is above group" <|
            \_ -> V.rank Platform |> Expect.equal 2
        , test "public is most exposed" <|
            \_ -> V.rank Public |> Expect.equal 3
        ]


exceedsCeilingRule : Test
exceedsCeilingRule =
    describe "exceedsCeiling: an option more permissive than the shelf ceiling is rejected"
        [ test "public under a platform shelf exceeds the ceiling (rejected)" <|
            \_ -> V.exceedsCeiling Platform Public |> Expect.equal True
        , test "platform under a platform shelf is allowed" <|
            \_ -> V.exceedsCeiling Platform Platform |> Expect.equal False
        , test "owner under a platform shelf is allowed (more restrictive)" <|
            \_ -> V.exceedsCeiling Platform Owner |> Expect.equal False
        , test "public under an owner shelf exceeds the ceiling" <|
            \_ -> V.exceedsCeiling Owner Public |> Expect.equal True
        , test "platform under an owner shelf exceeds the ceiling" <|
            \_ -> V.exceedsCeiling Owner Platform |> Expect.equal True
        , test "any option under a public shelf is allowed" <|
            \_ ->
                [ Public, Platform, Owner ]
                    |> List.map (V.exceedsCeiling Public)
                    |> Expect.equal [ False, False, False ]
        ]


placementOptionsForCeiling : Test
placementOptionsForCeiling =
    describe "placementOptions greys out options that exceed the shelf ceiling"
        [ test "platform ceiling disables the public option only" <|
            \_ ->
                V.placementOptions Platform
                    |> List.map (\o -> ( V.toString o.visibility, o.disabled ))
                    |> Expect.equal
                        [ ( "public", True )
                        , ( "platform", False )
                        , ( "owner", False )
                        ]
        , test "public ceiling enables every option" <|
            \_ ->
                V.placementOptions Public
                    |> List.map .disabled
                    |> Expect.equal [ False, False, False ]
        , test "the platform option is labelled \"Members\" for readers" <|
            \_ ->
                V.placementOptions Public
                    |> List.filter (\o -> o.visibility == Platform)
                    |> List.map .label
                    |> Expect.equal [ "Members" ]
        , test "owner ceiling disables both public and platform" <|
            \_ ->
                V.placementOptions Owner
                    |> List.map (\o -> ( V.toString o.visibility, o.disabled ))
                    |> Expect.equal
                        [ ( "public", True )
                        , ( "platform", True )
                        , ( "owner", False )
                        ]
        ]


ceilingHelperTextRule : Test
ceilingHelperTextRule =
    describe "ceilingHelperText explains a restricting ceiling, and is silent for public"
        [ test "a public ceiling restricts nothing, so there is no helper text" <|
            \_ -> V.ceilingHelperText Public |> Expect.equal Nothing
        , test "a members (platform) ceiling names itself in the helper text" <|
            \_ ->
                V.ceilingHelperText Platform
                    |> Maybe.map (String.contains "Members")
                    |> Expect.equal (Just True)
        , test "an owner ceiling produces helper text" <|
            \_ -> V.ceilingHelperText Owner |> Expect.notEqual Nothing
        ]
