module Page.Admin.MetricsProgramTest exposing (suite)

{-| Program tests for Page.Admin.Metrics using elm-program-test.

Exercises the admin `/admin/metrics` dashboard lifecycle through simulated HTTP
responses. The backend (StacksWeb.MetricsController) wraps every response in a
`{"data": ...}` envelope; these tests feed exactly that envelope shape and assert
that each of the four sections renders REAL decoded values (not silent proto
defaults, not a hard decode Failure):

1.  getMetrics unwraps `data` -> Data Quality banner + GDPR card render real values
2.  getEnrichmentGaps unwraps `data` -> three gap cards render real integers
3.  getQualityTrends unwraps `data` -> reaches Success and a trend arrow renders
4.  getSourceHealth unwraps `data` -> rows render from the #262 plain-string shape
5.  Cost ledger renders USD ($ from cents), header "Amount (USD)" (not ZAR)
6.  Neutral ("stable") trend renders the -> arrow

The four simulated requests share the production decoders (Api.metricsDashboardDecoder,
Api.qualityTrendsDecoder, Api.sourceHealthListDecoder, Api.enrichmentGapsDecoder) so
the envelope-unwrap contract under test is the real one, not a re-implementation.

-}

import Api
import Page.Admin.Metrics as Metrics
import ProgramTest exposing (ProgramDefinition, SimulatedEffect)
import SimulatedEffect.Cmd
import SimulatedEffect.Http
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector


suite : Test
suite =
    describe "Page.Admin.Metrics (ProgramTest)"
        [ metricsUnwrapsDataEnvelope
        , enrichmentGapsUnwrapsDataEnvelope
        , qualityTrendsUnwrapsDataEnvelope
        , sourceHealthUnwrapsDataEnvelope
        , costLedgerRendersUsd
        , neutralTrendRendersArrow
        ]



-- PROGRAM


start : ProgramTest.ProgramTest Metrics.Model Metrics.Msg (SimulatedEffect Metrics.Msg)
start =
    ProgramTest.start () program


program : ProgramDefinition () Metrics.Model Metrics.Msg (SimulatedEffect Metrics.Msg)
program =
    ProgramTest.createElement
        { init =
            \() ->
                let
                    ( model, _ ) =
                        Metrics.init (Just "test-token")
                in
                ( model, initEffects )
        , update =
            \msg model ->
                let
                    ( newModel, _, _ ) =
                        Metrics.update msg model
                in
                ( newModel, SimulatedEffect.Cmd.none )
        , view = Metrics.view
        }
        |> ProgramTest.withSimulatedEffects identity


{-| Mirror Page.Admin.Metrics.init's four parallel requests, keeping the exact
production decoders so the tests exercise the real `{data: ...}` envelope contract.
-}
initEffects : SimulatedEffect Metrics.Msg
initEffects =
    SimulatedEffect.Cmd.batch
        [ SimulatedEffect.Http.get
            { url = "/api/metrics"
            , expect = SimulatedEffect.Http.expectJson Metrics.DashboardReceived Api.metricsDashboardDecoder
            }
        , SimulatedEffect.Http.get
            { url = "/api/metrics/quality-trends"
            , expect = SimulatedEffect.Http.expectJson Metrics.QualityTrendsReceived Api.qualityTrendsDecoder
            }
        , SimulatedEffect.Http.get
            { url = "/api/metrics/source-health"
            , expect = SimulatedEffect.Http.expectJson Metrics.SourceHealthReceived Api.sourceHealthListDecoder
            }
        , SimulatedEffect.Http.get
            { url = "/api/metrics/enrichment-gaps"
            , expect = SimulatedEffect.Http.expectJson Metrics.EnrichmentGapsReceived Api.enrichmentGapsDecoder
            }
        ]



-- PAYLOADS (all wrapped in the backend {"data": ...} envelope)


{-| GET /api/metrics — cover\_pct 87.5, gdpr images pending 128, one USD cost line
of 1309 cents ($13.09). quality\_trends here feed the banner percentages only.
-}
metricsPayload : String
metricsPayload =
    """
    {
      "data": {
        "system_health": {"db_size_bytes": 1048576, "total_books": 500, "total_users": 50, "total_placements": 900, "generated_at": "2026-07-20T00:00:00Z"},
        "job_stats": [],
        "data_freshness": {"status": "ok"},
        "costs": {
          "total_cents": 1309,
          "currency": "USD",
          "cost_per_book": 0.03,
          "categories": [
            {"category": "hosting", "total_cents": 1309, "items": [{"service": "fly_compute", "description": "Compute VM", "amount_cents": 1309}]}
          ],
          "metrics": {"books": 500, "uploads": 10, "placements": 900, "db_size_bytes": 1048576, "avg_upload_payload_bytes": 100, "vision_jobs_this_month": 5},
          "monthly_totals": [],
          "generated_at": "2026-07-20T00:00:00Z"
        },
        "gdpr": {"images_pending_deletion": 128, "users_with_consent": 40, "generated_at": "2026-07-20T00:00:00Z"},
        "quality_trends": [
          {"snapshot_date": "2026-07-20", "total_books": 500, "books_with_covers": 437, "books_with_prices": 316, "books_with_reviews": 209, "total_sources": 5, "healthy_sources": 4, "cover_pct": 87.5, "price_pct": 63.2, "review_pct": 41.9}
        ],
        "source_health": [],
        "enrichment_gaps": {"status": "ok", "books_without_prices": 184, "books_without_covers": 63, "books_without_reviews": 291},
        "generated_at": "2026-07-20T00:00:00Z"
      }
    }
    """


{-| GET /api/metrics/enrichment-gaps — real gap integers 314 / 205 / 176.
-}
enrichmentGapsPayload : String
enrichmentGapsPayload =
    """
    {
      "data": {"status": "ok", "books_without_prices": 314, "books_without_covers": 205, "books_without_reviews": 176}
    }
    """


{-| GET /api/metrics/quality-trends — two rows, cover rising 80 -> 90 (an "up" trend).
-}
qualityTrendsUpPayload : String
qualityTrendsUpPayload =
    """
    {
      "data": [
        {"snapshot_date": "2026-07-20", "total_books": 500, "books_with_covers": 450, "books_with_prices": 350, "books_with_reviews": 250, "total_sources": 5, "healthy_sources": 5, "cover_pct": 90.0, "price_pct": 70.0, "review_pct": 50.0},
        {"snapshot_date": "2026-07-19", "total_books": 500, "books_with_covers": 400, "books_with_prices": 300, "books_with_reviews": 200, "total_sources": 5, "healthy_sources": 4, "cover_pct": 80.0, "price_pct": 60.0, "review_pct": 40.0}
      ]
    }
    """


{-| GET /api/metrics/quality-trends — two rows with identical percentages (a
neutral "stable" trend that must render the -> arrow).
-}
qualityTrendsStablePayload : String
qualityTrendsStablePayload =
    """
    {
      "data": [
        {"snapshot_date": "2026-07-20", "total_books": 500, "books_with_covers": 425, "books_with_prices": 325, "books_with_reviews": 225, "total_sources": 5, "healthy_sources": 5, "cover_pct": 50.0, "price_pct": 50.0, "review_pct": 50.0},
        {"snapshot_date": "2026-07-19", "total_books": 500, "books_with_covers": 425, "books_with_prices": 325, "books_with_reviews": 225, "total_sources": 5, "healthy_sources": 5, "cover_pct": 50.0, "price_pct": 50.0, "review_pct": 50.0}
      ]
    }
    """


{-| GET /api/metrics/source-health — the #262 plain-string shape: source\_type and
status are plain strings (not proto enums), plus last\_success\_at / last\_failure\_at.
-}
sourceHealthPayload : String
sourceHealthPayload =
    """
    {
      "data": [
        {"name": "Google Books", "source_type": "review_source", "status": "degraded", "consecutive_failures": 4, "last_success_at": "2026-07-19T10:00:00Z", "last_failure_at": "2026-07-20T02:00:00Z"}
      ]
    }
    """



-- TESTS


metricsUnwrapsDataEnvelope : Test
metricsUnwrapsDataEnvelope =
    test "getMetrics_unwraps_data: Data Quality banner + GDPR card render real decoded values" <|
        \() ->
            start
                |> ProgramTest.simulateHttpOk "GET" "/api/metrics" metricsPayload
                |> ProgramTest.ensureViewHas [ Selector.text "87.5%" ]
                |> ProgramTest.ensureViewHas [ Selector.text "63.2%" ]
                |> ProgramTest.expectViewHas
                    [ Selector.all
                        [ Selector.class "metrics-card__value"
                        , Selector.exactText "128"
                        ]
                    ]


enrichmentGapsUnwrapsDataEnvelope : Test
enrichmentGapsUnwrapsDataEnvelope =
    test "getEnrichmentGaps_unwraps_data: three gap cards render real integer counts" <|
        \() ->
            start
                |> ProgramTest.simulateHttpOk "GET" "/api/metrics/enrichment-gaps" enrichmentGapsPayload
                |> ProgramTest.ensureViewHas [ Selector.all [ Selector.class "metrics-card__value", Selector.exactText "314" ] ]
                |> ProgramTest.ensureViewHas [ Selector.all [ Selector.class "metrics-card__value", Selector.exactText "205" ] ]
                |> ProgramTest.expectViewHas [ Selector.all [ Selector.class "metrics-card__value", Selector.exactText "176" ] ]


qualityTrendsUnwrapsDataEnvelope : Test
qualityTrendsUnwrapsDataEnvelope =
    test "getQualityTrends_unwraps_data: reaches Success and renders a trend arrow" <|
        \() ->
            start
                |> ProgramTest.simulateHttpOk "GET" "/api/metrics" metricsPayload
                |> ProgramTest.simulateHttpOk "GET" "/api/metrics/quality-trends" qualityTrendsUpPayload
                |> ProgramTest.expectViewHas
                    [ Selector.all
                        [ Selector.class "metrics-card__trend"
                        , Selector.text "↑"
                        ]
                    ]


sourceHealthUnwrapsDataEnvelope : Test
sourceHealthUnwrapsDataEnvelope =
    test "getSourceHealth_unwraps_data: rows render from the #262 plain-string shape" <|
        \() ->
            start
                |> ProgramTest.simulateHttpOk "GET" "/api/metrics/source-health" sourceHealthPayload
                |> ProgramTest.ensureViewHas [ Selector.text "Google Books" ]
                |> ProgramTest.ensureViewHas [ Selector.text "review_source" ]
                |> ProgramTest.ensureViewHas [ Selector.all [ Selector.class "status-badge", Selector.text "degraded" ] ]
                |> ProgramTest.expectViewHas [ Selector.all [ Selector.tag "td", Selector.exactText "4" ] ]


costLedgerRendersUsd : Test
costLedgerRendersUsd =
    test "cost_ledger_usd: header reads Amount (USD) and a $-prefixed value renders from cents" <|
        \() ->
            start
                |> ProgramTest.simulateHttpOk "GET" "/api/metrics" metricsPayload
                |> ProgramTest.ensureViewHas [ Selector.text "Amount (USD)" ]
                |> ProgramTest.ensureViewHasNot [ Selector.text "Amount (ZAR)" ]
                |> ProgramTest.expectViewHas [ Selector.text "$13.09" ]


neutralTrendRendersArrow : Test
neutralTrendRendersArrow =
    test "neutral_trend: a stable trend renders the neutral arrow" <|
        \() ->
            start
                |> ProgramTest.simulateHttpOk "GET" "/api/metrics" metricsPayload
                |> ProgramTest.simulateHttpOk "GET" "/api/metrics/quality-trends" qualityTrendsStablePayload
                |> ProgramTest.expectViewHas
                    [ Selector.all
                        [ Selector.class "metrics-card__trend"
                        , Selector.text "→"
                        ]
                    ]
