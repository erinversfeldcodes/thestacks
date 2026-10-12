module Page.MetricsProgramTest exposing (suite)

{-| Program tests for Page.Metrics using elm-program-test.

Exercises the public `/metrics` transparency page lifecycle through simulated
HTTP responses. No authentication is required. Covers the four RemoteData states
(loading / loaded / live-unavailable / error), the teaching tooltips, the
featured costs widget, and the data-rights links.

-}

import Api
import Html.Attributes
import Http
import Page.Metrics as Metrics
import ProgramTest exposing (ProgramDefinition, SimulatedEffect)
import SimulatedEffect.Cmd
import SimulatedEffect.Http
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector


suite : Test
suite =
    describe "Page.Metrics (ProgramTest)"
        [ showsLoadingState
        , loadAndDisplayPanels
        , displaysTeachingTooltips
        , featuresCostsWidget
        , showsDataRightsLinks
        , degradesWhenLiveUnavailable
        , showsErrorState
        ]


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
                        Metrics.init
                in
                ( model, initEffects )
        , update =
            \msg model ->
                let
                    ( newModel, _ ) =
                        Metrics.update msg model
                in
                ( newModel, SimulatedEffect.Cmd.none )
        , view = Metrics.view
        }
        |> ProgramTest.withSimulatedEffects identity


initEffects : SimulatedEffect Metrics.Msg
initEffects =
    SimulatedEffect.Http.get
        { url = "/api/transparency/metrics"
        , expect =
            SimulatedEffect.Http.expectJson
                Metrics.MetricsReceived
                Api.transparencyMetricsDecoder
        }


livePayload : String
livePayload =
    """
    {
      "live": [
        {"key":"isbn_not_found_rate","label":"ISBN-not-found rate","what":"How often a scanned book cannot be matched.","how":"Counted at the moderation step.","why":"Operators watch this to spot a broken source.","unit":"per_second","value":0.5}
      ],
      "durable": [
        {"key":"total_books","label":"Books catalogued","what":"The total number of distinct works.","how":"A count of rows in the books table.","why":"The simplest honest measure of the library.","unit":"books","value":42},
        {"key":"platform_cost_cents","label":"Platform cost this period","what":"What it costs to run the platform.","how":"The sum of infrastructure line items.","why":"Running a platform costs money.","unit":"usd_cents","value":1309}
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
        {"key":"total_books","label":"Books catalogued","what":"The total number of distinct works.","how":"A count of rows in the books table.","why":"The simplest honest measure of the library.","unit":"books","value":42}
      ],
      "generated_at":"2026-07-16T12:00:00.000000Z",
      "cache_ttl":45
    }
    """


showsLoadingState : Test
showsLoadingState =
    test "loading_state: shows a loading message before data arrives" <|
        \() ->
            start
                |> ProgramTest.expectViewHas
                    [ Selector.text "Loading transparency data..." ]


loadAndDisplayPanels : Test
loadAndDisplayPanels =
    test "loaded: renders live signal + durable stat panels" <|
        \() ->
            start
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/transparency/metrics"
                    livePayload
                |> ProgramTest.ensureViewHas [ Selector.text "ISBN-not-found rate" ]
                |> ProgramTest.ensureViewHas [ Selector.text "Books catalogued" ]
                |> ProgramTest.expectViewHas [ Selector.text "Platform cost this period" ]


displaysTeachingTooltips : Test
displaysTeachingTooltips =
    test "loaded: each panel exposes what/how/why teaching text" <|
        \() ->
            start
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/transparency/metrics"
                    livePayload
                |> ProgramTest.ensureViewHas [ Selector.text "The total number of distinct works." ]
                |> ProgramTest.ensureViewHas [ Selector.text "A count of rows in the books table." ]
                |> ProgramTest.expectViewHas [ Selector.text "The simplest honest measure of the library." ]


featuresCostsWidget : Test
featuresCostsWidget =
    test "loaded: features the platform-cost figure and the free-lunch thesis" <|
        \() ->
            start
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/transparency/metrics"
                    livePayload
                |> ProgramTest.ensureViewHas [ Selector.attribute (Html.Attributes.attribute "data-testid" "metrics-costs-widget") ]
                |> ProgramTest.ensureViewHas [ Selector.text "$13.09" ]
                |> ProgramTest.expectViewHas [ Selector.text "no such thing as a free lunch in software" ]


showsDataRightsLinks : Test
showsDataRightsLinks =
    test "loaded: shows one-hop data-rights links in the what-we-observe area" <|
        \() ->
            start
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/transparency/metrics"
                    livePayload
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.href "/settings/privacy") ]
                |> ProgramTest.expectViewHas
                    [ Selector.attribute (Html.Attributes.href "/settings/consent") ]


degradesWhenLiveUnavailable : Test
degradesWhenLiveUnavailable =
    test "live_unavailable: degrades gracefully but still shows durable stats" <|
        \() ->
            start
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/transparency/metrics"
                    unavailablePayload
                |> ProgramTest.ensureViewHas [ Selector.text "currently unavailable" ]
                |> ProgramTest.expectViewHas [ Selector.text "Books catalogued" ]


showsErrorState : Test
showsErrorState =
    test "error_state: shows an error message on HTTP failure" <|
        \() ->
            start
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/transparency/metrics"
                    Http.NetworkError_
                |> ProgramTest.expectViewHas
                    [ Selector.text "could not be loaded" ]
