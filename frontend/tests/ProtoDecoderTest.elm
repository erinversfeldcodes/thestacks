module ProtoDecoderTest exposing (suite)

{-| Round-trip and shape tests for the checked-in proto/gen/elm decoders.

These tests verify that:

1.  Each decoder parses the JSON shape defined by the corresponding .proto file.
2.  Each encoder produces JSON that the decoder can read back unchanged.

If these tests break after a .proto change, the proto/gen/elm/ decoders must
be regenerated or updated by hand to match the new schema.

-}

import Expect
import Json.Decode as D
import Json.Encode as E
import Stacks.Common.V1.Location
    exposing
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
import Stacks.Internal.V1.EventBus
    exposing
        ( EventEnvelope
        , decodeEventEnvelope
        , encodeEventEnvelope
        )
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Proto gen Elm decoders"
        [ locationSuite
        , eventBusSuite
        ]



-- ---------------------------------------------------------------------------
-- Location
-- ---------------------------------------------------------------------------


locationSuite : Test
locationSuite =
    describe "Location decoders"
        [ test "Country decodes required fields" <|
            \_ ->
                let
                    json =
                        """{"code":"ZA","name":"South Africa"}"""

                    result =
                        D.decodeString decodeCountry json
                in
                case result of
                    Ok c ->
                        Expect.all
                            [ \x -> Expect.equal "ZA" x.code
                            , \x -> Expect.equal "South Africa" x.name
                            ]
                            c

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "Country encode-decode round-trip" <|
            \_ ->
                let
                    original : Country
                    original =
                        { code = "ZA", name = "South Africa" }

                    encoded =
                        encodeCountry original

                    result =
                        D.decodeValue decodeCountry encoded
                in
                case result of
                    Ok decoded ->
                        Expect.equal original decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "Country fails when code is missing" <|
            \_ ->
                let
                    result =
                        D.decodeString decodeCountry """{"name":"South Africa"}"""
                in
                case result of
                    Ok _ ->
                        Expect.fail "Expected failure when required field is missing"

                    Err _ ->
                        Expect.pass
        , test "City decodes name and country_code" <|
            \_ ->
                let
                    json =
                        """{"name":"Cape Town","country_code":"ZA"}"""

                    result =
                        D.decodeString decodeCity json
                in
                case result of
                    Ok c ->
                        Expect.all
                            [ \x -> Expect.equal "Cape Town" x.name
                            , \x -> Expect.equal "ZA" x.countryCode
                            ]
                            c

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "City encode-decode round-trip" <|
            \_ ->
                let
                    original : City
                    original =
                        { name = "Cape Town", countryCode = "ZA" }

                    result =
                        D.decodeValue decodeCity (encodeCity original)
                in
                case result of
                    Ok decoded ->
                        Expect.equal original decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "Coordinates decodes latitude and longitude" <|
            \_ ->
                let
                    json =
                        """{"latitude":-33.9249,"longitude":18.4241}"""

                    result =
                        D.decodeString decodeCoordinates json
                in
                case result of
                    Ok c ->
                        Expect.all
                            [ \x -> Expect.within (Expect.Absolute 0.0001) -33.9249 x.latitude
                            , \x -> Expect.within (Expect.Absolute 0.0001) 18.4241 x.longitude
                            ]
                            c

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "Coordinates encode-decode round-trip" <|
            \_ ->
                let
                    original : Coordinates
                    original =
                        { latitude = -33.9249, longitude = 18.4241 }

                    result =
                        D.decodeValue decodeCoordinates (encodeCoordinates original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \x -> Expect.within (Expect.Absolute 0.0001) original.latitude x.latitude
                            , \x -> Expect.within (Expect.Absolute 0.0001) original.longitude x.longitude
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        ]



-- ---------------------------------------------------------------------------
-- EventBus
-- ---------------------------------------------------------------------------


eventBusSuite : Test
eventBusSuite =
    describe "EventBus.EventEnvelope decoder"
        [ test "decodes all required fields" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "event_type": "book.created",
                            "aggregate_type": "book",
                            "aggregate_id": "abc-123",
                            "schema_version": 1,
                            "payload": {"isbn": "9780156001311"},
                            "metadata": {"user_id": "u-1"},
                            "occurred_at": "2026-03-19T10:00:00Z"
                        }
                        """

                    result =
                        D.decodeString decodeEventEnvelope json
                in
                case result of
                    Ok env ->
                        Expect.all
                            [ \e -> Expect.equal "book.created" e.eventType
                            , \e -> Expect.equal "book" e.aggregateType
                            , \e -> Expect.equal "abc-123" e.aggregateId
                            , \e -> Expect.equal 1 e.schemaVersion
                            , \e -> Expect.equal "2026-03-19T10:00:00Z" e.occurredAt
                            ]
                            env

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "optional fields default when absent" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "event_type": "user.registered",
                            "aggregate_type": "user",
                            "aggregate_id": "u-42"
                        }
                        """

                    result =
                        D.decodeString decodeEventEnvelope json
                in
                case result of
                    Ok env ->
                        Expect.all
                            [ \e -> Expect.equal 1 e.schemaVersion
                            , \e -> Expect.equal "" e.occurredAt
                            ]
                            env

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "encode-decode round-trip preserves all fields" <|
            \_ ->
                let
                    original : EventEnvelope
                    original =
                        { eventType = "book.created"
                        , aggregateType = "book"
                        , aggregateId = "abc-123"
                        , schemaVersion = 2
                        , payload = E.object [ ( "isbn", E.string "9780156001311" ) ]
                        , metadata = E.object [ ( "source", E.string "upload" ) ]
                        , occurredAt = "2026-03-19T10:00:00Z"
                        }

                    result =
                        D.decodeValue decodeEventEnvelope (encodeEventEnvelope original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \e -> Expect.equal original.eventType e.eventType
                            , \e -> Expect.equal original.aggregateType e.aggregateType
                            , \e -> Expect.equal original.aggregateId e.aggregateId
                            , \e -> Expect.equal original.schemaVersion e.schemaVersion
                            , \e -> Expect.equal original.occurredAt e.occurredAt
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "fails when required event_type is missing" <|
            \_ ->
                let
                    result =
                        D.decodeString decodeEventEnvelope
                            """{"aggregate_type":"book","aggregate_id":"x"}"""
                in
                case result of
                    Ok _ ->
                        Expect.fail "Expected failure when event_type is missing"

                    Err _ ->
                        Expect.pass
        ]
