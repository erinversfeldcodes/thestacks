module Stacks.Common.V1.Location exposing
    ( City
    , Coordinates
    , Country
    , decodeCity
    , decodeCoordinates
    , decodeCountry
    , encodeCity
    , encodeCoordinates
    , encodeCountry
    )

{-| Generated Elm JSON decoders/encoders for stacks.common.v1 location.proto.

DO NOT EDIT MANUALLY. Regenerate via scripts/gen-elm-proto.sh after modifying location.proto.

JSON on the wire — these decoders consume the JSON representation of the Protobuf messages.
Field numbers are not present in JSON; json\_name attributes from the .proto file determine keys.

-}

import Json.Decode as D
import Json.Encode as E


type alias Country =
    { code : String
    , name : String
    }


decodeCountry : D.Decoder Country
decodeCountry =
    D.map2 Country
        (D.field "code" D.string)
        (D.field "name" D.string)


encodeCountry : Country -> E.Value
encodeCountry country =
    E.object
        [ ( "code", E.string country.code )
        , ( "name", E.string country.name )
        ]


type alias City =
    { name : String
    , countryCode : String
    }


decodeCity : D.Decoder City
decodeCity =
    D.map2 City
        (D.field "name" D.string)
        (D.field "country_code" D.string)


encodeCity : City -> E.Value
encodeCity city =
    E.object
        [ ( "name", E.string city.name )
        , ( "country_code", E.string city.countryCode )
        ]


type alias Coordinates =
    { latitude : Float
    , longitude : Float
    }


decodeCoordinates : D.Decoder Coordinates
decodeCoordinates =
    D.map2 Coordinates
        (D.field "latitude" D.float)
        (D.field "longitude" D.float)


encodeCoordinates : Coordinates -> E.Value
encodeCoordinates coords =
    E.object
        [ ( "latitude", E.float coords.latitude )
        , ( "longitude", E.float coords.longitude )
        ]
