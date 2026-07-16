module Page.InsightsProgramTest exposing (suite)

{-| Program tests for Page.Insights using elm-program-test.

Exercises the authed own-only personal-inference view lifecycle:

  - loading -> loaded render (de-anon explanation + interest subjects visible),
  - the risk section is HIDDEN until the explicit reveal action, then visible,
  - the `insufficient_data` de-anon state renders its message,
  - the error state renders.

The reveal action re-fetches `GET /api/me/inferences?reveal_risk=true`; the
program's update maps that click to a simulated HTTP effect so the reveal path
is exercised end-to-end.

-}

import Api
import Http
import Page.Insights as Insights
import ProgramTest exposing (ProgramDefinition, SimulatedEffect)
import SimulatedEffect.Cmd
import SimulatedEffect.Http
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector


token : String
token =
    "test-token"


suite : Test
suite =
    describe "Page.Insights (ProgramTest)"
        [ showsLoadingState
        , loadAndDisplay
        , riskHiddenUntilRevealed
        , revealFetchesAndShowsRisk
        , insufficientDataState
        , showsErrorState
        ]


start : ProgramTest.ProgramTest Insights.Model Insights.Msg (SimulatedEffect Insights.Msg)
start =
    ProgramTest.start () program


program : ProgramDefinition () Insights.Model Insights.Msg (SimulatedEffect Insights.Msg)
program =
    ProgramTest.createElement
        { init =
            \() ->
                let
                    ( model, _ ) =
                        Insights.init (Just token)
                in
                ( model, initEffects )
        , update =
            \msg model ->
                let
                    ( newModel, _, _ ) =
                        Insights.update msg model
                in
                ( newModel
                , case msg of
                    Insights.RevealRiskRequested ->
                        revealEffects

                    _ ->
                        SimulatedEffect.Cmd.none
                )
        , view = Insights.view
        }
        |> ProgramTest.withSimulatedEffects identity


initEffects : SimulatedEffect Insights.Msg
initEffects =
    SimulatedEffect.Http.request
        { method = "GET"
        , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
        , url = "/api/me/inferences"
        , body = SimulatedEffect.Http.emptyBody
        , expect = SimulatedEffect.Http.expectJson Insights.InferencesReceived Api.personalInferencesDecoder
        , timeout = Nothing
        , tracker = Nothing
        }


revealEffects : SimulatedEffect Insights.Msg
revealEffects =
    SimulatedEffect.Http.request
        { method = "GET"
        , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
        , url = "/api/me/inferences?reveal_risk=true"
        , body = SimulatedEffect.Http.emptyBody
        , expect = SimulatedEffect.Http.expectJson Insights.RiskRevealReceived Api.personalInferencesDecoder
        , timeout = Nothing
        , tracker = Nothing
        }


defaultPayload : String
defaultPayload =
    """
    {
      "interest_profile": {
        "top_subjects": [{"subject": "philosophy", "count": 3}, {"subject": "history", "count": 2}],
        "top_bisac": [{"code": "OCC000000", "count": 2}]
      },
      "behaviour": {
        "books_shelved": 4, "books_finished": 2, "books_abandoned": 1,
        "abandonment_rate": 0.25, "median_days_to_finish": 10, "most_active_hour": 14
      },
      "deanonymisation": {
        "sample_size": 5, "others_sharing_all": 0, "uniqueness": "unique",
        "explanation": "No other reader here shares all 5 of your rarest books."
      },
      "generated_at": "2026-07-16T08:05:52.380000Z"
    }
    """


revealPayload : String
revealPayload =
    """
    {
      "interest_profile": {
        "top_subjects": [{"subject": "philosophy", "count": 3}],
        "top_bisac": [{"code": "OCC000000", "count": 2}]
      },
      "behaviour": {
        "books_shelved": 4, "books_finished": 2, "books_abandoned": 1,
        "abandonment_rate": 0.25, "median_days_to_finish": 10, "most_active_hour": 14
      },
      "deanonymisation": {
        "sample_size": 5, "others_sharing_all": 0, "uniqueness": "unique",
        "explanation": "No other reader here shares all 5 of your rarest books."
      },
      "risk_inferences": [
        {"label": "Inferred topic interest",
         "could_infer": "A data broker could infer an interest in philosophy from your subject clusters.",
         "basis": "subject cluster: philosophy"}
      ],
      "generated_at": "2026-07-16T08:05:52.380000Z"
    }
    """


insufficientPayload : String
insufficientPayload =
    """
    {
      "interest_profile": {"top_subjects": [], "top_bisac": []},
      "behaviour": {
        "books_shelved": 1, "books_finished": 0, "books_abandoned": 0,
        "abandonment_rate": 0.0, "median_days_to_finish": null, "most_active_hour": null
      },
      "deanonymisation": {
        "sample_size": 1, "others_sharing_all": null, "uniqueness": "insufficient_data",
        "explanation": "Shelve more books to see how identifiable you are."
      },
      "generated_at": "2026-07-16T08:05:52.380000Z"
    }
    """


showsLoadingState : Test
showsLoadingState =
    test "loading_state: shows a loading message before data arrives" <|
        \() ->
            start
                |> ProgramTest.expectViewHas
                    [ Selector.text "Working out what your data reveals..." ]


loadAndDisplay : Test
loadAndDisplay =
    test "loaded: renders de-anon explanation + interest subjects" <|
        \() ->
            start
                |> ProgramTest.simulateHttpOk "GET" "/api/me/inferences" defaultPayload
                |> ProgramTest.ensureViewHas [ Selector.text "No other reader here shares all 5 of your rarest books." ]
                |> ProgramTest.ensureViewHas [ Selector.text "philosophy, history" ]
                |> ProgramTest.expectViewHas [ Selector.text "you are a fingerprint" ]


riskHiddenUntilRevealed : Test
riskHiddenUntilRevealed =
    test "consent_gate: risk illustrations are hidden until the reveal action" <|
        \() ->
            start
                |> ProgramTest.simulateHttpOk "GET" "/api/me/inferences" defaultPayload
                |> ProgramTest.ensureViewHas [ Selector.text "Show me what could be inferred" ]
                |> ProgramTest.expectViewHasNot
                    [ Selector.text "A data broker could infer an interest in philosophy from your subject clusters." ]


revealFetchesAndShowsRisk : Test
revealFetchesAndShowsRisk =
    test "reveal: clicking the consent button re-fetches with risk and shows the labelled illustrations" <|
        \() ->
            start
                |> ProgramTest.simulateHttpOk "GET" "/api/me/inferences" defaultPayload
                |> ProgramTest.clickButton "Show me what could be inferred"
                |> ProgramTest.simulateHttpOk "GET" "/api/me/inferences?reveal_risk=true" revealPayload
                |> ProgramTest.ensureViewHas [ Selector.text "A data broker could infer an interest in philosophy from your subject clusters." ]
                |> ProgramTest.expectViewHas [ Selector.text "not something we assert about you or store anywhere." ]


insufficientDataState : Test
insufficientDataState =
    test "insufficient_data: renders the shelve-more-books message" <|
        \() ->
            start
                |> ProgramTest.simulateHttpOk "GET" "/api/me/inferences" insufficientPayload
                |> ProgramTest.expectViewHas [ Selector.text "Shelve more books to see how identifiable you are." ]


showsErrorState : Test
showsErrorState =
    test "error_state: shows an error message on HTTP failure" <|
        \() ->
            start
                |> ProgramTest.simulateHttpResponse "GET" "/api/me/inferences" Http.NetworkError_
                |> ProgramTest.expectViewHas
                    [ Selector.text "This could not be loaded right now. Please try again." ]
