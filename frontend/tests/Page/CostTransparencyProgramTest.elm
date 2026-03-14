module Page.CostTransparencyProgramTest exposing (suite)

{-| Program tests for Page.CostTransparency using elm-program-test.

These tests exercise the Cost Transparency page lifecycle through
simulated HTTP responses. No authentication is required for this page.

-}

import Http
import Json.Encode as Encode
import Page.CostTransparency as CostTransparency exposing (Msg(..))
import ProgramTest exposing (ProgramDefinition, SimulatedEffect)
import SimulatedEffect.Cmd
import SimulatedEffect.Http
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import Types.RemoteData exposing (RemoteData(..))


suite : Test
suite =
    describe "Page.CostTransparency (ProgramTest)"
        [ loadAndDisplayCosts
        , showsLoadingState
        , showsErrorState
        , displaysTotalAndCostPerBook
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
                    [ ( "line_items"
                      , Encode.list identity
                            [ costItemJson "hosting" "Fly.io Core" "Phoenix API server" 534
                            , costItemJson "compute" "Modal Vision API" "Vision inference" 200
                            , costItemJson "database" "Neon PostgreSQL" "Serverless DB" 0
                            , costItemJson "domain" "Domain Registration" "Annual domain" 100
                            ]
                      )
                    , ( "total_cents", Encode.int 834 )
                    , ( "currency", Encode.string "USD" )
                    , ( "cost_per_book", Encode.float 0.42 )
                    , ( "book_count", Encode.int 20 )
                    , ( "monthly_totals"
                      , Encode.list identity
                            [ monthlyTotalJson "2026-01-01T00:00:00Z" "2026-01-31T23:59:59Z" 750
                            , monthlyTotalJson "2026-02-01T00:00:00Z" "2026-02-28T23:59:59Z" 800
                            , monthlyTotalJson "2026-03-01T00:00:00Z" "2026-03-31T23:59:59Z" 834
                            ]
                      )
                    , ( "generated_at", Encode.string "2026-03-14T12:00:00Z" )
                    ]
              )
            ]
        )


costItemJson : String -> String -> String -> Int -> Encode.Value
costItemJson category service description amountCents =
    Encode.object
        [ ( "category", Encode.string category )
        , ( "service", Encode.string service )
        , ( "description", Encode.string description )
        , ( "amount_cents", Encode.int amountCents )
        , ( "currency", Encode.string "USD" )
        , ( "period_start", Encode.string "2026-03-01T00:00:00Z" )
        , ( "period_end", Encode.string "2026-03-31T23:59:59Z" )
        ]


monthlyTotalJson : String -> String -> Int -> Encode.Value
monthlyTotalJson start end totalCents =
    Encode.object
        [ ( "period_start", Encode.string start )
        , ( "period_end", Encode.string end )
        , ( "total_cents", Encode.int totalCents )
        ]


loadAndDisplayCosts : Test
loadAndDisplayCosts =
    test "load_costs: init fetches data -> renders cost table with line items" <|
        \() ->
            startCostPage
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/costs"
                    sampleCostResponseJson
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Fly.io Core" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Modal Vision API" ]
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


displaysTotalAndCostPerBook : Test
displaysTotalAndCostPerBook =
    test "total_and_cost_per_book: displays summary cards" <|
        \() ->
            startCostPage
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/costs"
                    sampleCostResponseJson
                |> ProgramTest.ensureViewHas
                    [ Selector.text "$8.34" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "20" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "$0.42" ]


displaysPhilosophyNote : Test
displaysPhilosophyNote =
    test "philosophy_note: shows the transparency philosophy text" <|
        \() ->
            startCostPage
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/costs"
                    sampleCostResponseJson
                |> ProgramTest.expectViewHas
                    [ Selector.text "Every number here is real, unfiltered, and automated." ]


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
