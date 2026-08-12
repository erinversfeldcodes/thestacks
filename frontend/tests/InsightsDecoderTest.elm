module InsightsDecoderTest exposing (suite)

{-| Decoder tests for the personal-inferences payload (Api.personalInferencesDecoder).

Verifies the load-bearing decoder rules from issue:

  - `risk_inferences` is ABSENT (not null) in the default payload -> Nothing.
  - `risk_inferences` present in the reveal payload -> Just [... ].
  - `median_days_to_finish` / `most_active_hour` null -> Nothing.
  - `others_sharing_all` null -> Nothing; the `0` / "unique" case decodes.

-}

import Api
import Expect
import Json.Decode as Decode
import Test exposing (Test, describe, test)


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
        "abandonment_rate": 0.25, "median_days_to_finish": null, "most_active_hour": null
      },
      "deanonymisation": {
        "sample_size": 5, "others_sharing_all": null, "uniqueness": "insufficient_data",
        "explanation": "Shelve more books to see this."
      },
      "risk_inferences": [
        {"label": "Inferred topic interest",
         "could_infer": "A data broker could infer an interest in philosophy from your subject clusters.",
         "basis": "subject cluster: philosophy"}
      ],
      "generated_at": "2026-07-16T08:05:52.380000Z"
    }
    """


decode : String -> Result Decode.Error Api.PersonalInferences
decode json =
    Decode.decodeString Api.personalInferencesDecoder json


suite : Test
suite =
    describe "Api.personalInferencesDecoder"
        [ describe "default payload (risk not revealed)"
            [ test "decodes successfully" <|
                \() ->
                    decode defaultPayload
                        |> Result.map (\_ -> ())
                        |> Expect.equal (Ok ())
            , test "risk_inferences absent -> Nothing" <|
                \() ->
                    decode defaultPayload
                        |> Result.map .riskInferences
                        |> Expect.equal (Ok Nothing)
            , test "interest subjects decode in order" <|
                \() ->
                    decode defaultPayload
                        |> Result.map (.interestProfile >> .topSubjects >> List.map .subject)
                        |> Expect.equal (Ok [ "philosophy", "history" ])
            , test "top_bisac decodes code + count" <|
                \() ->
                    decode defaultPayload
                        |> Result.map (.interestProfile >> .topBisac)
                        |> Expect.equal (Ok [ { code = "OCC000000", count = 2 } ])
            , test "abandonment_rate decodes as float" <|
                \() ->
                    decode defaultPayload
                        |> Result.map (.behaviour >> .abandonmentRate)
                        |> Expect.equal (Ok 0.25)
            , test "present median/hour -> Just" <|
                \() ->
                    decode defaultPayload
                        |> Result.map (\p -> ( p.behaviour.medianDaysToFinish, p.behaviour.mostActiveHour ))
                        |> Expect.equal (Ok ( Just 10, Just 14 ))
            , test "others_sharing_all 0 + uniqueness unique decode" <|
                \() ->
                    decode defaultPayload
                        |> Result.map (\p -> ( p.deanonymisation.othersSharingAll, p.deanonymisation.uniqueness ))
                        |> Expect.equal (Ok ( Just 0, "unique" ))
            ]
        , describe "reveal payload (risk revealed, null ints)"
            [ test "risk_inferences present -> Just list decodes" <|
                \() ->
                    decode revealPayload
                        |> Result.map (.riskInferences >> Maybe.map (List.map .label))
                        |> Expect.equal (Ok (Just [ "Inferred topic interest" ]))
            , test "risk inference basis + could_infer decode" <|
                \() ->
                    decode revealPayload
                        |> Result.map (.riskInferences >> Maybe.andThen List.head >> Maybe.map .basis)
                        |> Expect.equal (Ok (Just "subject cluster: philosophy"))
            , test "null median_days_to_finish / most_active_hour -> Nothing" <|
                \() ->
                    decode revealPayload
                        |> Result.map (\p -> ( p.behaviour.medianDaysToFinish, p.behaviour.mostActiveHour ))
                        |> Expect.equal (Ok ( Nothing, Nothing ))
            , test "null others_sharing_all -> Nothing" <|
                \() ->
                    decode revealPayload
                        |> Result.map (.deanonymisation >> .othersSharingAll)
                        |> Expect.equal (Ok Nothing)
            , test "insufficient_data uniqueness decodes" <|
                \() ->
                    decode revealPayload
                        |> Result.map (.deanonymisation >> .uniqueness)
                        |> Expect.equal (Ok "insufficient_data")
            ]
        ]
