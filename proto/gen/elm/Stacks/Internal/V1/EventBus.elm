module Stacks.Internal.V1.EventBus exposing
    ( EventEnvelope
    , decodeEventEnvelope
    , encodeEventEnvelope
    )

{-| Generated Elm JSON decoders/encoders for stacks.internal.v1 event\_bus.proto.

DO NOT EDIT MANUALLY. Regenerate via scripts/gen-elm-proto.sh after modifying event\_bus.proto.

JSON on the wire — these decoders consume the JSON representation of the Protobuf messages.
Field numbers are not present in JSON; json\_name attributes from the .proto file determine keys.

google.protobuf.Struct maps to Json.Encode.Value (arbitrary JSON object).
google.protobuf.Timestamp maps to a string in RFC3339 format (Protobuf JSON encoding).

-}

import Json.Decode as D
import Json.Encode as E


type alias EventEnvelope =
    { eventType : String
    , aggregateType : String
    , aggregateId : String
    , schemaVersion : Int
    , payload : E.Value
    , metadata : E.Value
    , occurredAt : String
    }


decodeEventEnvelope : D.Decoder EventEnvelope
decodeEventEnvelope =
    D.map7 EventEnvelope
        (D.field "event_type" D.string)
        (D.field "aggregate_type" D.string)
        (D.field "aggregate_id" D.string)
        (D.oneOf [ D.field "schema_version" D.int, D.succeed 1 ])
        (D.oneOf [ D.field "payload" D.value, D.succeed (E.object []) ])
        (D.oneOf [ D.field "metadata" D.value, D.succeed (E.object []) ])
        (D.oneOf [ D.field "occurred_at" D.string, D.succeed "" ])


encodeEventEnvelope : EventEnvelope -> E.Value
encodeEventEnvelope env =
    E.object
        [ ( "event_type", E.string env.eventType )
        , ( "aggregate_type", E.string env.aggregateType )
        , ( "aggregate_id", E.string env.aggregateId )
        , ( "schema_version", E.int env.schemaVersion )
        , ( "payload", env.payload )
        , ( "metadata", env.metadata )
        , ( "occurred_at", E.string env.occurredAt )
        ]
