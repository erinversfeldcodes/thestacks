module MainSwipeDecodeTest exposing (suite)

{-| Decoder tests for `Main.decodeSwipe`, the port-inbound handler that turns a
raw swipe payload into a `Msg`. A valid string payload becomes
`SwipeReceived <direction>`; anything that is not a JSON string is ignored as
`SwipeIgnored` (fail-closed — a malformed gesture never navigates).
-}

import Expect
import Json.Encode as Encode
import Main
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Main.decodeSwipe"
        [ test "a 'left' string payload decodes to SwipeReceived \"left\"" <|
            \() ->
                Main.decodeSwipe (Encode.string "left")
                    |> Expect.equal (Main.SwipeReceived "left")
        , test "a 'right' string payload decodes to SwipeReceived \"right\"" <|
            \() ->
                Main.decodeSwipe (Encode.string "right")
                    |> Expect.equal (Main.SwipeReceived "right")
        , test "a non-string number payload is ignored (SwipeIgnored)" <|
            \() ->
                Main.decodeSwipe (Encode.int 7)
                    |> Expect.equal Main.SwipeIgnored
        , test "an object payload is ignored (SwipeIgnored)" <|
            \() ->
                Main.decodeSwipe (Encode.object [ ( "direction", Encode.string "left" ) ])
                    |> Expect.equal Main.SwipeIgnored
        , test "a null payload is ignored (SwipeIgnored)" <|
            \() ->
                Main.decodeSwipe Encode.null
                    |> Expect.equal Main.SwipeIgnored
        ]
