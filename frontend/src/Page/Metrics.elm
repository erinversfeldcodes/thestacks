module Page.Metrics exposing
    ( Model
    , Msg(..)
    , init
    , update
    , view
    )

{-| The public, unauthenticated transparency page (`/metrics`,).

Renders the curated payload — live ops signals and durable anonymised
aggregates — each panel showing its value plus a teaching expander with the
plain-language _what / how / why_ (the public analogue of the self-explanatory-dashboard standard). A featured costs widget makes the
platform-cost figure the flagship example, and the "what we observe"
area links one hop to the GDPR data-rights surfaces.

No new backend: this consumes `Api.getTransparencyMetrics` only. It renders
whatever the curated endpoint serves and degrades gracefully when the live
section is `unavailable` (Prometheus unconfigured) or the whole fetch fails.

-}

import Api exposing (LiveSignals(..), TransparencyEntry, TransparencyMetrics)
import Html exposing (Html, a, details, div, h1, h2, h3, p, section, span, summary, text)
import Html.Attributes exposing (class, href, rel, target)
import Http
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


type alias Model =
    { metrics : RemoteData Http.Error TransparencyMetrics
    }


init : ( Model, Cmd Msg )
init =
    ( { metrics = Loading }
    , Api.getTransparencyMetrics MetricsReceived
    )


type Msg
    = MetricsReceived (Result Http.Error TransparencyMetrics)


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        MetricsReceived result ->
            ( { model | metrics = Types.RemoteData.fromResult result }
            , Cmd.none
            )


view : Model -> Html Msg
view model =
    div [ class "page page--metrics curator-desk" ]
        [ h1 [ class "page__title metrics__title" ] [ text "What we measure" ]
        , p [ class "metrics__subtitle" ]
            [ text "Everything we measure about ourselves (The Stacks platform) and you (our users) is made visible here, with the exception of anything that can be used to identify folks. That data is made visible to its owners (the users who took the actions that resulted in the metric being produced) only via their personal metrics page, available on login. The reason for this level of transparency is discussed in greater detail in "
            , a [ class "metrics__rights-link", href "/transparency", testId "metrics-transparency-essay-link" ]
                [ text "this piece" ]
            , text "."
            ]
        , case model.metrics of
            NotAsked ->
                text ""

            Loading ->
                div [ class "metrics__loading", testId "metrics-loading" ]
                    [ text "Loading transparency data..." ]

            Failure _ ->
                p [ class "metrics__error", testId "metrics-error" ]
                    [ text "Transparency data could not be loaded right now. Please try again later." ]

            Success metrics ->
                viewMetrics metrics
        ]


viewMetrics : TransparencyMetrics -> Html Msg
viewMetrics metrics =
    div [ class "metrics__content", testId "metrics-content" ]
        [ viewCostsWidget metrics.durable
        , viewLiveSection metrics.live
        , viewDurableSection metrics.durable
        , viewObserveSection
        ]


viewCostsWidget : List TransparencyEntry -> Html Msg
viewCostsWidget durable =
    let
        maybeCost =
            durable
                |> List.filter (\e -> e.key == "platform_cost_cents")
                |> List.head
    in
    case maybeCost of
        Just cost ->
            section [ class "metrics__costs", testId "metrics-costs-widget" ]
                [ h2 [ class "metrics__costs-title" ] [ text "What it costs to run The Stacks" ]
                , div [ class "metrics__costs-figure" ]
                    [ span [ class "metrics__costs-amount" ] [ text (formatCents cost.value) ]
                    , span [ class "metrics__costs-caption" ] [ text cost.label ]
                    ]
                , p [ class "metrics__costs-prose" ]
                    [ text "Running a platform costs real money, so here is what it costs to run. This is currently all self-funded, so if you're not on the invite-list: read the code, take inspiration, and build something similar for yourself — but be a mensch and don't fork this one, or I'll have to come find you every time I fix a bug of my own :) For a full discussion of why all of these expenses are incurred and what the trade offs are, please see "
                    , a [ class "metrics__rights-link", href "/architecture", testId "metrics-architecture-essay-link" ]
                        [ text "this essay on the system's architecture" ]
                    , text ". I hope it helps you understand why there's no such thing as a free lunch in software, and makes you push for answers from anyone claiming they're offering you something truly free of charge (no nasty terms of service turning you into a data harvesting machine)."
                    ]
                , viewTeaching cost
                ]

        Nothing ->
            text ""


viewLiveSection : LiveSignals -> Html Msg
viewLiveSection live =
    section [ class "metrics__section metrics__section--live", testId "metrics-live-section" ]
        [ h2 [ class "metrics__section-title" ] [ text "Live signals" ]
        , p [ class "metrics__section-lede" ]
            [ text "These are the dashboards I use to monitor the health of the site, how it's performing, and to do deep dives to understand why things might have gone wrong when they inevitably do. Feel free to take a look and let me know "
            , a
                [ class "metrics__rights-link"
                , href "https://github.com/erinversfeldcodes/thestacks/discussions"
                , target "_blank"
                , rel "noopener noreferrer"
                , testId "metrics-discussions-link"
                ]
                [ text "on the repo's discussion board" ]
            , text " if anything looks fishy or interesting to you."
            ]
        , case live of
            LiveSignals entries ->
                div [ class "metrics__grid" ] (List.map viewPanel entries)

            LiveUnavailable ->
                p [ class "metrics__unavailable", testId "metrics-live-unavailable" ]
                    [ text "Live signals are currently unavailable. The durable figures below are still accurate." ]
        ]


viewDurableSection : List TransparencyEntry -> Html Msg
viewDurableSection durable =
    section [ class "metrics__section metrics__section--durable", testId "metrics-durable-section" ]
        [ h2 [ class "metrics__section-title" ] [ text "Durable statistics" ]
        , p [ class "metrics__section-lede" ]
            [ text "Some more metrics, nerds love numbers." ]
        , div [ class "metrics__grid" ] (List.map viewPanel durable)
        ]


viewPanel : TransparencyEntry -> Html Msg
viewPanel entry =
    div [ class "metrics__panel", testId "metrics-panel" ]
        [ div [ class "metrics__panel-head" ]
            [ span [ class "metrics__panel-label" ] [ text entry.label ]
            , span [ class "metrics__panel-value" ] [ text (formatValue entry) ]
            ]
        , viewTeaching entry
        ]


{-| The "why we measure this" teaching expander — a native `<details>` so it is
keyboard-accessible and needs no JavaScript. Renders the plain-language
what/how/why for the entry.
-}
viewTeaching : TransparencyEntry -> Html Msg
viewTeaching entry =
    details [ class "metrics__teaching", testId "metrics-teaching" ]
        [ summary [ class "metrics__teaching-summary" ] [ text "What is this?" ]
        , p [ class "metrics__teaching-what" ]
            [ span [ class "metrics__teaching-label" ] [ text "What: " ], text entry.what ]
        , p [ class "metrics__teaching-how" ]
            [ span [ class "metrics__teaching-label" ] [ text "How: " ], text entry.how ]
        , p [ class "metrics__teaching-why" ]
            [ span [ class "metrics__teaching-label" ] [ text "Why: " ], text entry.why ]
        ]


viewObserveSection : Html Msg
viewObserveSection =
    section [ class "metrics__section metrics__section--observe", testId "metrics-observe-section" ]
        [ h2 [ class "metrics__section-title" ] [ text "What we observe about you" ]
        , p [ class "metrics__observe-prose" ]
            [ text "Everything above is an aggregate. Your own data is yours: you can export or erase it at any time." ]
        , div [ class "metrics__rights" ]
            [ h3 [ class "metrics__rights-title" ] [ text "Your data rights" ]
            , a [ class "metrics__rights-link", href "/settings/privacy" ]
                [ text "Export or delete your data" ]
            , a [ class "metrics__rights-link", href "/settings/consent" ]
                [ text "Manage your consent" ]
            ]
        , div [ class "metrics__dashboards" ]
            [ h3 [ class "metrics__rights-title" ] [ text "The full picture" ]
            , p [ class "metrics__observe-prose" ]
                [ text "These curated signals are drawn from the same live dashboards our operators use. You can see the whole set." ]
            , a
                [ class "metrics__dashboards-link"
                , href grafanaUrl
                , target "_blank"
                , rel "noopener noreferrer"
                , testId "metrics-grafana-link"
                ]
                [ text "See the full operational dashboards →" ]
            ]
        ]


{-| The public, read-only Grafana instance — a single fixed
public URL, so it is a constant rather than server-config. Anonymous access; the
metrics store behind it is never exposed (Grafana proxies queries server-side).
-}
grafanaUrl : String
grafanaUrl =
    "https://thestacks-grafana.fly.dev"


formatValue : TransparencyEntry -> String
formatValue entry =
    case entry.unit of
        "usd_cents" ->
            formatCents entry.value

        "percent" ->
            formatNumber entry.value ++ "%"

        "per_second" ->
            formatNumber entry.value ++ "/s"

        "boolean" ->
            if entry.value >= 0.5 then
                "Yes"

            else
                "No"

        other ->
            formatNumber entry.value ++ " " ++ other


{-| Format a USD-cents figure (a `Float` carrying whole cents) as `$X.XX`.
-}
formatCents : Float -> String
formatCents cents =
    let
        rounded =
            round cents

        dollars =
            rounded // 100

        remainder =
            modBy 100 rounded

        centStr =
            if remainder < 10 then
                "0" ++ String.fromInt remainder

            else
                String.fromInt remainder
    in
    "$" ++ String.fromInt dollars ++ "." ++ centStr


{-| Render a number without a trailing `.0` when it is a whole value, so counts
read as `42` while rates keep a decimal (`0.5`).
-}
formatNumber : Float -> String
formatNumber value =
    if value == toFloat (round value) then
        String.fromInt (round value)

    else
        String.fromFloat value
