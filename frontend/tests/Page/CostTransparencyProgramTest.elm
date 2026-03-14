module Page.CostTransparencyProgramTest exposing (suite)

{-| Program tests for Page.CostTransparency using elm-program-test.

These tests exercise the Cost Transparency page lifecycle through
simulated HTTP responses. No authentication is required for this page.

-}

import Http
import Json.Encode as Encode
import Page.CostTransparency as CostTransparency
import ProgramTest exposing (ProgramDefinition, SimulatedEffect)
import SimulatedEffect.Cmd
import SimulatedEffect.Http
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector


suite : Test
suite =
    describe "Page.CostTransparency (ProgramTest)"
        [ loadAndDisplayCosts
        , showsLoadingState
        , showsErrorState
        , displaysTotalBanner
        , displaysStoryCards
        , displaysPhilosophyNote
        , displaysMonthlyTrend
        ]


startCostPage : ProgramTest.ProgramTest CostTransparency.Model CostTransparency.Msg (SimulatedEffect CostTransparency.Msg)
startCostPage =
    ProgramTest.start () costTransparencyProgram


costTransparencyProgram : ProgramDefinition () CostTransparency.Model CostTransparency.Msg (SimulatedEffect CostTransparency.Msg)
costTransparencyProgram =
    ProgramTest.createElement
        { init =
            \() ->
                let
                    ( model, _ ) =
                        CostTransparency.init
                in
                ( model, costInitEffects )
        , update =
            \msg model ->
                let
                    ( newModel, _ ) =
                        CostTransparency.update msg model
                in
                ( newModel, SimulatedEffect.Cmd.none )
        , view = CostTransparency.view
        }
        |> ProgramTest.withSimulatedEffects identity


costInitEffects : SimulatedEffect CostTransparency.Msg
costInitEffects =
    SimulatedEffect.Http.get
        { url = "/api/costs"
        , expect =
            SimulatedEffect.Http.expectJson
                CostTransparency.CostsReceived
                CostTransparency.costBreakdownDecoder
        }


sampleCostResponseJson : String
sampleCostResponseJson =
    Encode.encode 0
        (Encode.object
            [ ( "data"
              , Encode.object
                    [ ( "total_cents", Encode.int 1309 )
                    , ( "currency", Encode.string "USD" )
                    , ( "cost_per_book", Encode.float 1.19 )
                    , ( "categories"
                      , Encode.list identity
                            [ categoryJson "hosting"
                                1068
                                [ serviceJson "Fly.io Core" "Phoenix API + Elm SPA (shared-cpu-1x, 512MB, IAD)" 534
                                , serviceJson "Fly.io Vision Sidecar" "FastAPI HMAC proxy to Modal" 534
                                ]
                            , categoryJson "compute"
                                141
                                [ serviceJson "Modal GPU Inference" "Qwen2.5-VL-7B on A10G" 141
                                ]
                            , categoryJson "domain"
                                100
                                [ serviceJson "Domain Registration" "thestacks.app" 100
                                ]
                            , categoryJson "database"
                                0
                                [ serviceJson "Neon PostgreSQL" "Serverless Postgres (free tier)" 0
                                ]
                            ]
                      )
                    , ( "metrics"
                      , Encode.object
                            [ ( "books", Encode.int 11 )
                            , ( "uploads", Encode.int 5 )
                            , ( "placements", Encode.int 2 )
                            , ( "db_size_bytes", Encode.int 8929280 )
                            , ( "avg_upload_payload_bytes", Encode.int 0 )
                            , ( "vision_jobs_this_month", Encode.int 47 )
                            ]
                      )
                    , ( "monthly_totals"
                      , Encode.list identity
                            [ monthlyTotalJson "2026-01-01T00:00:00Z" "2026-01-31T23:59:59Z" 1200
                            , monthlyTotalJson "2026-02-01T00:00:00Z" "2026-02-28T23:59:59Z" 1250
                            , monthlyTotalJson "2026-03-01T00:00:00Z" "2026-03-31T23:59:59Z" 1309
                            ]
                      )
                    , ( "generated_at", Encode.string "2026-03-14T12:00:00Z" )
                    ]
              )
            ]
        )


categoryJson : String -> Int -> List Encode.Value -> Encode.Value
categoryJson category totalCents items =
    Encode.object
        [ ( "category", Encode.string category )
        , ( "total_cents", Encode.int totalCents )
        , ( "items", Encode.list identity items )
        ]


serviceJson : String -> String -> Int -> Encode.Value
serviceJson service description amountCents =
    Encode.object
        [ ( "service", Encode.string service )
        , ( "description", Encode.string description )
        , ( "amount_cents", Encode.int amountCents )
        ]


monthlyTotalJson : String -> String -> Int -> Encode.Value
monthlyTotalJson periodStart periodEnd totalCents =
    Encode.object
        [ ( "period_start", Encode.string periodStart )
        , ( "period_end", Encode.string periodEnd )
        , ( "total_cents", Encode.int totalCents )
        ]


loadAndDisplayCosts : Test
loadAndDisplayCosts =
    test "load_costs: init fetches data -> renders service names in category cards" <|
        \() ->
            startCostPage
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/costs"
                    sampleCostResponseJson
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Fly.io Core" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Modal GPU Inference" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Neon PostgreSQL" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Domain Registration" ]


showsLoadingState : Test
showsLoadingState =
    test "loading_state: shows loading message before data arrives" <|
        \() ->
            startCostPage
                |> ProgramTest.expectViewHas
                    [ Selector.text "Loading cost data..." ]


showsErrorState : Test
showsErrorState =
    test "error_state: shows error message on HTTP failure" <|
        \() ->
            startCostPage
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/costs"
                    Http.NetworkError_
                |> ProgramTest.expectViewHas
                    [ Selector.text "Failed to load cost data." ]


displaysTotalBanner : Test
displaysTotalBanner =
    test "total_banner: displays total monthly cost" <|
        \() ->
            startCostPage
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/costs"
                    sampleCostResponseJson
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Total monthly cost" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "$13.09" ]


displaysStoryCards : Test
displaysStoryCards =
    test "story_cards: displays three story sections with metrics" <|
        \() ->
            startCostPage
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/costs"
                    sampleCostResponseJson
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Upload & Identify" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Store & Shelve" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "47 identifications" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "11 books" ]


displaysPhilosophyNote : Test
displaysPhilosophyNote =
    test "philosophy_note: shows the transparency philosophy text" <|
        \() ->
            startCostPage
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/costs"
                    sampleCostResponseJson
                |> ProgramTest.expectViewHas
                    [ Selector.text "Every number on this page is real." ]


displaysMonthlyTrend : Test
displaysMonthlyTrend =
    test "monthly_trend: shows monthly trend section with bars" <|
        \() ->
            startCostPage
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/costs"
                    sampleCostResponseJson
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Monthly Trend" ]
                |> ProgramTest.expectViewHas
                    [ Selector.class "costs__chart" ]
