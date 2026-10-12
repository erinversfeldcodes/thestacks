module OptionalFieldDecoderTest exposing (suite)

{-| An optional field must distinguish "absent" from "wrong".

`optionalString` was built as `Decode.oneOf [ field, Decode.succeed "" ]`, and
`oneOf` falls through on ANY failure of the first branch — not just an absent
key. So a field arriving as a number, a list or an object decoded to `""`
exactly as a genuinely-unset one did. The reader saw an empty city, an empty
handle, an empty display name, and nothing anywhere reported that the server
had sent something the client could not read.

That is the same class as a payload whose shape is valid and whose content is a
lie: the decode succeeds, so no error surfaces, and the blank is indistinguishable
from a real blank.

-}

import Api
import Expect
import Json.Decode as Decode
import Test exposing (Test, describe, test)


{-| A `GET /api/auth/me` body with `display_name` set to whatever is passed.
-}
accountWith : String -> String
accountWith displayNameJson =
    """{"user":{"display_name":""" ++ displayNameJson ++ ""","handle":"ada","email":"ada@example.com"}}"""


decodeDisplayName : String -> Result Decode.Error String
decodeDisplayName json =
    Decode.decodeString Api.accountDecoder json
        |> Result.map .displayName


suite : Test
suite =
    describe "optional string fields"
        [ describe "the cases that should default" <|
            [ test "an absent key is not a malformed response" <|
                \() ->
                    """{"user":{"handle":"ada","email":"ada@example.com"}}"""
                        |> decodeDisplayName
                        |> Expect.equal (Ok "")
            , test "an explicit null is not a malformed response" <|
                \() ->
                    accountWith "null"
                        |> decodeDisplayName
                        |> Expect.equal (Ok "")
            , test "a present string decodes to itself" <|
                \() ->
                    accountWith "\"Ada\""
                        |> decodeDisplayName
                        |> Expect.equal (Ok "Ada")
            ]
        , describe "the cases that must NOT be laundered into a blank" <|
            List.map
                (\( label, json ) ->
                    test ("a " ++ label ++ " is a decode failure, not an empty string") <|
                        \() ->
                            case decodeDisplayName (accountWith json) of
                                Ok value ->
                                    Expect.fail
                                        ("decoded to "
                                            ++ Debug.toString value
                                            ++ " — a wrong-typed field was silently turned into a blank"
                                        )

                                Err _ ->
                                    Expect.pass
                )
                [ ( "number", "42" )
                , ( "boolean", "true" )
                , ( "list", "[\"Ada\"]" )
                , ( "object", "{\"first\":\"Ada\"}" )
                ]
        ]
