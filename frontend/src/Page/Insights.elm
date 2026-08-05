module Page.Insights exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

{-| Personal inference & de-anonymisation education view (authed, own-only).

The authenticated counterpart to the public `/metrics` page. Shows a signed-in
user ONLY their own data-derived inferences, computed live from their own
records and never persisted, to educate on:

  - what can be inferred about them from their behaviour, and
  - how they could be de-anonymised even though the platform keeps no PII.

Everything shown is ephemeral — nothing here is stored, and it is computed from
the user's own data only. The sensitive "what could be inferred" section is
hidden behind an explicit consent-to-view action; clicking it re-fetches the
same endpoint with `?reveal_risk=true`.

Design: ADR-019 §3a. Issue #242.

-}

import Api exposing (Behaviour, Deanonymisation, InterestProfile, PersonalInferences, RiskInference, SubjectCount)
import Html exposing (Html, button, div, h1, h2, li, p, span, strong, text, ul)
import Html.Attributes exposing (class)
import Html.Events exposing (onClick)
import Http
import Types.RemoteData exposing (RemoteData(..))
import Util.Plural
import Util.TestId exposing (testId)


type alias Model =
    { token : Maybe String
    , data : RemoteData Http.Error PersonalInferences
    , riskLoading : Bool
    , riskError : Bool
    }


type Msg
    = InferencesReceived (Result Http.Error PersonalInferences)
    | RevealRiskRequested
    | RiskRevealReceived (Result Http.Error PersonalInferences)


type OutMsg
    = NoOut
    | SessionExpired


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    case maybeToken of
        Just token ->
            ( { token = Just token
              , data = Loading
              , riskLoading = False
              , riskError = False
              }
            , Api.getInferences False token InferencesReceived
            )

        Nothing ->
            ( { token = Nothing
              , data = NotAsked
              , riskLoading = False
              , riskError = False
              }
            , Cmd.none
            )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        InferencesReceived result ->
            case result of
                Ok payload ->
                    ( { model | data = Success payload }, Cmd.none, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | data = Failure err }, Cmd.none, NoOut )

        RevealRiskRequested ->
            case model.token of
                Just token ->
                    ( { model | riskLoading = True, riskError = False }
                    , Api.getInferences True token RiskRevealReceived
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        RiskRevealReceived result ->
            case result of
                Ok payload ->
                    ( { model | data = Success payload, riskLoading = False, riskError = False }
                    , Cmd.none
                    , NoOut
                    )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | riskLoading = False, riskError = True }, Cmd.none, NoOut )



-- VIEW


view : Model -> Html Msg
view model =
    div [ class "page page--insights", testId "insights-page" ]
        [ h1 [ class "page__title" ] [ text "What your data reveals" ]
        , p [ class "insights__intro" ]
            [ text "This is computed live from your own records, just for you. "
            , strong [] [ text "Nothing on this page is stored" ]
            , text " — it is worked out fresh each time you visit and then forgotten. No one else can see it, and it only ever uses your own data."
            ]
        , viewContent model
        ]


viewContent : Model -> Html Msg
viewContent model =
    case model.data of
        NotAsked ->
            text ""

        Loading ->
            div [ class "loading" ] [ text "Working out what your data reveals..." ]

        Failure _ ->
            p [ class "error" ] [ text "This could not be loaded right now. Please try again." ]

        Success payload ->
            div [ class "insights__sections" ]
                [ viewInterest payload.interestProfile
                , viewBehaviour payload.behaviour
                , viewDeanon payload.deanonymisation
                , viewRisk model payload
                ]



-- INTEREST PROFILE


viewInterest : InterestProfile -> Html Msg
viewInterest profile =
    div [ class "insights__section", testId "insights-interest" ]
        [ h2 [ class "insights__section-title" ] [ text "Your interests" ]
        , p [ class "insights__section-desc" ]
            [ text "These are plain facts drawn from the books on your shelves." ]
        , if List.isEmpty profile.topSubjects then
            p [ class "insights__empty" ]
                [ text "Shelve a few more books and your subject profile will appear here." ]

          else
            p [ class "insights__fact" ]
                [ text "Your shelf is mostly: "
                , strong [] [ text (subjectSummary profile.topSubjects) ]
                , text "."
                ]
        , if List.isEmpty profile.topBisac then
            text ""

          else
            div [ class "insights__bisac" ]
                [ p [ class "insights__section-desc" ]
                    [ text "The industry subject codes (BISAC) that recur most on your shelves:" ]
                , ul [ class "insights__list" ]
                    (List.map viewBisac profile.topBisac)
                ]
        ]


subjectSummary : List SubjectCount -> String
subjectSummary subjects =
    subjects
        |> List.map .subject
        |> String.join ", "


viewBisac : Api.BisacCount -> Html Msg
viewBisac bisac =
    li [ class "insights__list-item" ]
        [ span [ class "insights__code" ] [ text bisac.code ]
        , text (" — " ++ Util.Plural.books bisac.count)
        ]



-- BEHAVIOUR


viewBehaviour : Behaviour -> Html Msg
viewBehaviour behaviour =
    div [ class "insights__section", testId "insights-behaviour" ]
        [ h2 [ class "insights__section-title" ] [ text "How you read" ]
        , p [ class "insights__section-desc" ]
            [ text "These are factual patterns from the timing of your own activity." ]
        , ul [ class "insights__stats" ]
            ([ statItem "Books shelved" (String.fromInt behaviour.booksShelved)
             , statItem "Books finished" (String.fromInt behaviour.booksFinished)
             , statItem "Books abandoned" (String.fromInt behaviour.booksAbandoned)
             , statItem "Abandonment rate" (formatPercent behaviour.abandonmentRate)
             ]
                ++ maybeStat "Typical time to finish a book" (Maybe.map formatDays behaviour.medianDaysToFinish)
                ++ maybeStat "Your most active hour" (Maybe.map formatHour behaviour.mostActiveHour)
            )
        ]


statItem : String -> String -> Html Msg
statItem label value =
    li [ class "insights__stat" ]
        [ span [ class "insights__stat-label" ] [ text label ]
        , span [ class "insights__stat-value" ] [ text value ]
        ]


maybeStat : String -> Maybe String -> List (Html Msg)
maybeStat label maybeValue =
    case maybeValue of
        Just value ->
            [ statItem label value ]

        Nothing ->
            []



-- DE-ANONYMISATION (the centrepiece)


viewDeanon : Deanonymisation -> Html Msg
viewDeanon deanon =
    div [ class "insights__section insights__section--deanon", testId "insights-deanon" ]
        [ h2 [ class "insights__section-title" ] [ text "Could you be re-identified?" ]
        , viewDeanonBody deanon
        , p [ class "insights__deanon-explanation", testId "insights-deanon-explanation" ]
            [ text deanon.explanation ]
        ]


viewDeanonBody : Deanonymisation -> Html Msg
viewDeanonBody deanon =
    case deanon.uniqueness of
        "unique" ->
            div [ class "insights__deanon-headline insights__deanon-headline--unique" ]
                [ p [ class "insights__deanon-verdict" ]
                    [ text "On this platform, you are a fingerprint." ]
                , p [ class "insights__section-desc" ]
                    [ text "No other reader here shares your combination of rarest books. That uniqueness is enough to pick you out — a shelf can identify you as surely as a face, even though we never asked for your name." ]
                ]

        "rare" ->
            div [ class "insights__deanon-headline insights__deanon-headline--rare" ]
                [ p [ class "insights__deanon-verdict" ]
                    [ text "Your reading is close to unique here." ]
                , p [ class "insights__section-desc" ]
                    [ text "Only a handful of readers share your rarest books. That small a crowd is easy to narrow down — a couple of extra clues from elsewhere would be enough to single you out." ]
                ]

        "common" ->
            div [ class "insights__deanon-headline insights__deanon-headline--common" ]
                [ p [ class "insights__deanon-verdict" ]
                    [ text "You blend into the crowd — for now." ]
                , p [ class "insights__section-desc" ]
                    [ text "Plenty of readers here share your rarest books, so this shelf alone would not single you out. As you add more niche books, that changes quickly." ]
                ]

        "insufficient_data" ->
            div [ class "insights__deanon-headline insights__deanon-headline--insufficient" ]
                [ p [ class "insights__deanon-verdict" ]
                    [ text "Not enough on your shelves yet." ]
                , p [ class "insights__section-desc" ]
                    [ text "Shelve more books and we can show you how identifiable your combination is against everyone else here." ]
                ]

        _ ->
            div [ class "insights__deanon-headline insights__deanon-headline--unknown" ]
                [ p [ class "insights__deanon-verdict" ]
                    [ text "We couldn't work this out right now." ]
                , p [ class "insights__section-desc" ]
                    [ text "The uniqueness of your shelf could not be computed this time. Nothing has been recorded either way." ]
                ]



-- RISK INFERENCES (consent-gated)


viewRisk : Model -> PersonalInferences -> Html Msg
viewRisk model payload =
    div [ class "insights__section insights__section--risk", testId "insights-risk" ]
        [ h2 [ class "insights__section-title" ] [ text "What a third party could infer" ]
        , case payload.riskInferences of
            Just inferences ->
                viewRiskRevealed inferences

            Nothing ->
                viewRiskGate model
        ]


viewRiskGate : Model -> Html Msg
viewRiskGate model =
    div [ class "insights__risk-gate" ]
        [ p [ class "insights__section-desc" ]
            [ text "The next part illustrates what an outside party — a data broker, an advertiser — might guess about you from these same patterns. Some illustrations touch on sensitive topics, so we only show them if you ask." ]
        , if model.riskError then
            p [ class "error" ] [ text "That could not be loaded. Please try again." ]

          else
            text ""
        , button
            [ class "btn btn--secondary insights__risk-reveal"
            , testId "insights-reveal-risk"
            , onClick RevealRiskRequested
            ]
            [ text
                (if model.riskLoading then
                    "Revealing..."

                 else
                    "Show me what could be inferred"
                )
            ]
        ]


viewRiskRevealed : List RiskInference -> Html Msg
viewRiskRevealed inferences =
    div [ class "insights__risk-revealed", testId "insights-risk-revealed" ]
        [ p [ class "insights__risk-caveat" ]
            [ strong [] [ text "These are illustrations, not facts." ]
            , text " Each one is what a third party could infer — not something we assert about you or store anywhere."
            ]
        , if List.isEmpty inferences then
            p [ class "insights__empty" ]
                [ text "There isn't enough on your shelves yet to illustrate this." ]

          else
            ul [ class "insights__risk-list" ]
                (List.map viewRiskItem inferences)
        ]


viewRiskItem : RiskInference -> Html Msg
viewRiskItem inference =
    li [ class "insights__risk-item" ]
        [ span [ class "insights__risk-label" ] [ text inference.label ]
        , p [ class "insights__risk-could" ] [ text inference.couldInfer ]
        , p [ class "insights__risk-basis" ]
            [ text "Based on: ", text inference.basis ]
        ]



-- FORMATTING HELPERS


formatPercent : Float -> String
formatPercent rate =
    String.fromInt (round (rate * 100)) ++ "%"


formatDays : Int -> String
formatDays days =
    if days == 1 then
        "about 1 day"

    else
        "about " ++ String.fromInt days ++ " days"


formatHour : Int -> String
formatHour hour =
    let
        padded =
            String.padLeft 2 '0' (String.fromInt hour)
    in
    "around " ++ padded ++ ":00"
