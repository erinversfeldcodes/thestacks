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
        , absentLineShowsTextNotZero
        , measuredLineStillShowsMoney
        , unmeasuredIsMarkedForStyling
        , categoryHeaderSaysWhenIncomplete
        , storyCardUnitAttachesToTheMoney
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


{-| A response whose Compute category has one measured line and one absent one.

⛔ THE ABSENT CASE HAD NO ELM TEST AT ALL. A reviewer's probe rewrote
`amountText`'s absent arms back to `formatCents` — reinstating the `$0.00` this
whole issue exists to remove — and **all 2314 tests passed**. `grep` over
`frontend/tests/` found zero occurrences of "not yet measured" and zero of any
`CostBasis` constructor but `Measured`. The only guard was an E2E spec needing a
deployed stack that happens to have an unmeasured line, which made the headline
requirement deploy-gated to re-verify forever.

-}
mixedBasisResponseJson : String
mixedBasisResponseJson =
    Encode.encode 0
        (Encode.object
            [ ( "data"
              , Encode.object
                    [ ( "total_cents", Encode.int 500 )
                    , ( "currency", Encode.string "USD" )
                    , ( "cost_per_book", Encode.float 0.5 )
                    , ( "categories"
                      , Encode.list identity
                            [ categoryJson "compute"
                                500
                                [ basisServiceJson "Modal GPU" "d" 500 "rate_card"
                                , basisServiceJson "Together AI" "d" 0 "absent"
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
                    , ( "monthly_totals", Encode.list identity [] )
                    , ( "generated_at", Encode.string "2026-11-10T00:00:00Z" )
                    ]
              )
            ]
        )


startMixed : ProgramTest.ProgramTest CostTransparency.Model CostTransparency.Msg (SimulatedEffect CostTransparency.Msg)
startMixed =
    startCostPage
        |> ProgramTest.simulateHttpOk "GET" "/api/costs" mixedBasisResponseJson


absentLineShowsTextNotZero : Test
absentLineShowsTextNotZero =
    test "absent_line: an unmeasured line renders a sentence, not a currency zero" <|
        \() ->
            startMixed
                |> ProgramTest.expectViewHas
                    -- ⛔ SCOPED TO THE AMOUNT CELL, and the unscoped version was
                    -- VACUOUS. `Selector.text` is a containment match, and the
                    -- page's own closing sentence contains "or not yet measured
                    -- this period" — so a bare text assertion matched the
                    -- philosophy paragraph and passed with every line still
                    -- rendering $0.00. Caught by re-running the reviewer's probe
                    -- against my own new test rather than trusting it.
                    [ Selector.all
                        [ Selector.class "costs__service-amount--unmeasured"
                        , Selector.text "not yet measured this period"
                        ]
                    ]


{-| ⬛ ANTI-VACUITY: a page that rendered the sentence for EVERY line would
satisfy the case above while hiding every real figure.
-}
measuredLineStillShowsMoney : Test
measuredLineStillShowsMoney =
    test "absent_line: a line that has a figure still shows it" <|
        \() ->
            startMixed
                |> ProgramTest.expectViewHas [ Selector.text "$5.00" ]


{-| ⚖️ The modifier is what stops a sentence being dressed as a figure — the fix
for a browser finding where the amount column, sized for "$15.60", received a
30-character sentence and crushed the description to ~60px.
-}
unmeasuredIsMarkedForStyling : Test
unmeasuredIsMarkedForStyling =
    test "absent_line: the unmeasured cell carries its modifier and no currency" <|
        \() ->
            startMixed
                |> ProgramTest.expectViewHasNot
                    -- ⚖️ The modifier alone is not enough: `amountClass` is
                    -- independent of `amountText`, so a cell can carry the
                    -- modifier AND render money. What must not exist is an
                    -- unmeasured cell containing a currency figure.
                    [ Selector.all
                        [ Selector.class "costs__service-amount--unmeasured"
                        , Selector.text "$0.00"
                        ]
                    ]


{-| ⛔ The category header summed absent lines as money until a browser drive
caught it — "Compute $0.00" over one measured and one unmeasured line.
-}
categoryHeaderSaysWhenIncomplete : Test
categoryHeaderSaysWhenIncomplete =
    test "absent_line: the category header reports its unmeasured count" <|
        \() ->
            startMixed
                |> ProgramTest.expectViewHas [ Selector.text "+ 1 unmeasured" ]


{-| ⛔ "/mo" IS A SUFFIX ON A NUMBER, NOT ON A SENTENCE. When the aggregate fix
changed the story card's argument from an `Int` to rendered text, the card
shipped "$X.XX + 1 unmeasured/mo" — on the figure a reader sees first.
-}
storyCardUnitAttachesToTheMoney : Test
storyCardUnitAttachesToTheMoney =
    test "absent_line: the story card's /mo follows the money, not the note" <|
        \() ->
            startMixed
                |> ProgramTest.expectViewHas [ Selector.text "$5.00/mo" ]


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
        , ( "unmeasured_count"
          , Encode.int (List.length (List.filter isAbsentItem items))
          )
        , ( "items", Encode.list identity items )
        ]


serviceJson : String -> String -> Int -> Encode.Value
serviceJson service description amountCents =
    basisServiceJson service description amountCents "rate_card"


{-| A service line with an explicit basis.

⚖️ The three-argument form defaults to `rate_card` so every existing fixture
keeps its meaning; this one exists for the cases that need `absent`.

-}
basisServiceJson : String -> String -> Int -> String -> Encode.Value
basisServiceJson service description amountCents basis =
    Encode.object
        [ ( "service", Encode.string service )
        , ( "description", Encode.string description )
        , ( "amount_cents", Encode.int amountCents )
        , ( "basis", Encode.string basis )
        , ( "refreshed_at", Encode.string "" )
        ]


{-| Whether an encoded service line is an absent one.

⚖️ Derived from the items rather than passed in, so a fixture cannot declare a
count that disagrees with its own lines — which is the shape of the defect this
whole feature is about.

-}
isAbsentItem : Encode.Value -> Bool
isAbsentItem item =
    item
        |> Encode.encode 0
        |> String.contains "\"basis\":\"absent\""


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


{-| ⛔ THIS TEST PINNED A CLAIM THE PAGE COULD NOT KEEP.

It asserted "Every number on this page is real." — a sentence that was false in
two directions at once. Most lines are a published price times an observed
quantity, which is honest arithmetic and _is_ an estimate of spend since a
provider's invoice may differ; and five cost-item builders answered an
unavailable measurement with zero, so the page rendered "$0.00" for services it
had no measurement of, directly above that sentence.

⚖️ Reversed rather than deleted, because the page's purpose IS the claim. What
it now asserts is the per-line form, which the reader can check against the
basis shown beside each figure — a claim you can verify beats a claim you must
take on trust.

⚠️ AND NO COMPANION ABSENCE ASSERTION, deliberately. I added one — "the
unqualified every-number claim is absent" — and `check-prose-assertions.sh`
refused it, correctly: the string no longer appears anywhere in `frontend/src/`,
so nothing can make that assertion fail and it would keep passing if this page
were deleted entirely. An absence assertion on a string that does not exist is
unfalsifiable, which is the vacuity that gate exists to catch. The positive
assertion above is the real guard: restore the old sentence in place of the new
one and it reds.

-}
displaysPhilosophyNote : Test
displaysPhilosophyNote =
    test "philosophy_note: states how each figure was arrived at, per line" <|
        \() ->
            startCostPage
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/costs"
                    sampleCostResponseJson
                |> ProgramTest.expectViewHas
                    [ Selector.text "Each line above says how its figure was arrived at" ]


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
