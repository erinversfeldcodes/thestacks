module TransparencyDecoderTest exposing (suite)

{-| Decoder tests for the public transparency payload (→).

Confirms `Api.transparencyMetricsDecoder` matches the exact serialised shape of
`Stacks.Transparency.metrics/0`: `{live, durable, generated_at, cache_ttl}` where
`live` is either a list of entries or the string `"unavailable"`, and each entry
carries `key/label/what/how/why/unit/value`.

-}

import Api
import Expect
import Json.Decode as Decode
import Test exposing (Test, describe, test)


livePayload : String
livePayload =
    """
    {
      "live": [
        {"key":"isbn_not_found_rate","label":"ISBN-not-found rate","what":"how often a scan fails","how":"counted at moderation","why":"operators watch this","unit":"per_second","value":0.5},
        {"key":"breakers_healthy","label":"Circuit breakers healthy","what":"whether breakers are closed","how":"min of gauges","why":"core reliability signal","unit":"boolean","value":1}
      ],
      "durable": [
        {"key":"total_books","label":"Books catalogued","what":"total distinct works","how":"count of rows","why":"honest measure","unit":"books","value":42},
        {"key":"platform_cost_cents","label":"Platform cost this period","what":"what it costs to run","how":"sum of line items","why":"free platforms sell your data","unit":"usd_cents","value":1309}
      ],
      "profiles": [
        {"key":"enrichment_gaps","label":"Catalogue enrichment","what":"what share is missing each enrichment","how":"distinct works with no record over total","why":"a single score hides which half is thin","total_books":42,"dimensions":[
          {"dimension":"cover art","present":30,"missing":12,"missing_pct":28.6},
          {"dimension":"price data","present":20,"missing":22,"missing_pct":52.4},
          {"dimension":"sanctioned reviews","present":5,"missing":37,"missing_pct":88.1}
        ]}
      ],
      "generated_at":"2026-07-16T12:00:00.000000Z",
      "cache_ttl":45
    }
    """


unavailablePayload : String
unavailablePayload =
    """
    {
      "live":"unavailable",
      "durable":[
        {"key":"total_books","label":"Books catalogued","what":"total distinct works","how":"count of rows","why":"honest measure","unit":"books","value":42}
      ],
      "profiles": [
        {"key":"enrichment_gaps","label":"Catalogue enrichment","what":"what share is missing each enrichment","how":"distinct works with no record over total","why":"a single score hides which half is thin","total_books":42,"dimensions":[
          {"dimension":"cover art","present":30,"missing":12,"missing_pct":28.6},
          {"dimension":"price data","present":20,"missing":22,"missing_pct":52.4},
          {"dimension":"sanctioned reviews","present":5,"missing":37,"missing_pct":88.1}
        ]}
      ],
      "generated_at":"2026-07-16T12:00:00.000000Z",
      "cache_ttl":45
    }
    """


suite : Test
suite =
    describe "Api.transparencyMetricsDecoder"
        [ test "decodes a payload with live signals into LiveSignals" <|
            \() ->
                case Decode.decodeString Api.transparencyMetricsDecoder livePayload of
                    Ok metrics ->
                        case metrics.live of
                            Api.LiveSignals entries ->
                                List.length entries
                                    |> Expect.equal 2

                            Api.LiveUnavailable ->
                                Expect.fail "expected LiveSignals, got LiveUnavailable"

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "decodes the durable aggregates" <|
            \() ->
                case Decode.decodeString Api.transparencyMetricsDecoder livePayload of
                    Ok metrics ->
                        List.length metrics.durable
                            |> Expect.equal 2

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "decodes an entry's teaching metadata + value" <|
            \() ->
                case Decode.decodeString Api.transparencyMetricsDecoder livePayload of
                    Ok metrics ->
                        case List.head metrics.durable of
                            Just entry ->
                                Expect.all
                                    [ \e -> Expect.equal "total_books" e.key
                                    , \e -> Expect.equal "Books catalogued" e.label
                                    , \e -> Expect.equal "total distinct works" e.what
                                    , \e -> Expect.equal "count of rows" e.how
                                    , \e -> Expect.equal "honest measure" e.why
                                    , \e -> Expect.equal "books" e.unit
                                    , \e -> Expect.within (Expect.Absolute 0.001) 42.0 e.value
                                    ]
                                    entry

                            Nothing ->
                                Expect.fail "expected at least one durable entry"

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "decodes generated_at and cache_ttl" <|
            \() ->
                case Decode.decodeString Api.transparencyMetricsDecoder livePayload of
                    Ok metrics ->
                        Expect.all
                            [ \m -> Expect.equal "2026-07-16T12:00:00.000000Z" m.generatedAt
                            , \m -> Expect.equal 45 m.cacheTtl
                            ]
                            metrics

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "decodes live == \"unavailable\" into LiveUnavailable" <|
            \() ->
                case Decode.decodeString Api.transparencyMetricsDecoder unavailablePayload of
                    Ok metrics ->
                        case metrics.live of
                            Api.LiveUnavailable ->
                                Expect.pass

                            Api.LiveSignals _ ->
                                Expect.fail "expected LiveUnavailable, got LiveSignals"

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "still decodes durable stats when live is unavailable" <|
            \() ->
                case Decode.decodeString Api.transparencyMetricsDecoder unavailablePayload of
                    Ok metrics ->
                        List.length metrics.durable
                            |> Expect.equal 1

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "decodes the enrichment nutrition-label profile with its dimensions" <|
            \() ->
                case Decode.decodeString Api.transparencyMetricsDecoder livePayload of
                    Ok metrics ->
                        case List.head metrics.profiles of
                            Just profile ->
                                Expect.all
                                    [ \p -> Expect.equal "enrichment_gaps" p.key
                                    , \p -> Expect.equal 42 p.totalBooks
                                    , \p -> Expect.equal 3 (List.length p.dimensions)
                                    , \p ->
                                        case List.head p.dimensions of
                                            Just dim ->
                                                Expect.all
                                                    [ \d -> Expect.equal "cover art" d.dimension
                                                    , \d -> Expect.equal 30 d.present
                                                    , \d -> Expect.equal 12 d.missing
                                                    , \d -> Expect.within (Expect.Absolute 0.001) 28.6 d.missingPct
                                                    ]
                                                    dim

                                            Nothing ->
                                                Expect.fail "expected a dimension"
                                    ]
                                    profile

                            Nothing ->
                                Expect.fail "expected at least one profile"

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        ]
