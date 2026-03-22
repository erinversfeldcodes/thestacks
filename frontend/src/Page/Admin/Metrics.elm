module Page.Admin.Metrics exposing
    ( Model
    , Msg(..)
    , init
    , update
    , view
    )

{-| Admin Metrics Dashboard page.

Curator's desk aesthetic. Fetches from 4 endpoints in parallel,
each section uses RemoteData independently.

-}

import Api exposing (EnrichmentGaps, MetricsDashboard, QualityTrends, SourceHealth)
import Html exposing (Html, div, h1, h2, p, span, table, tbody, td, text, th, thead, tr)
import Html.Attributes exposing (class)
import Http
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { dashboard : RemoteData Http.Error MetricsDashboard
    , qualityTrends : RemoteData Http.Error QualityTrends
    , sourceHealth : RemoteData Http.Error (List SourceHealth)
    , enrichmentGaps : RemoteData Http.Error EnrichmentGaps
    }


type Msg
    = DashboardReceived (Result Http.Error MetricsDashboard)
    | QualityTrendsReceived (Result Http.Error QualityTrends)
    | SourceHealthReceived (Result Http.Error (List SourceHealth))
    | EnrichmentGapsReceived (Result Http.Error EnrichmentGaps)


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    let
        model =
            { dashboard = Loading
            , qualityTrends = Loading
            , sourceHealth = Loading
            , enrichmentGaps = Loading
            }
    in
    case maybeToken of
        Just token ->
            ( model
            , Cmd.batch
                [ Api.getMetrics token DashboardReceived
                , Api.getQualityTrends token QualityTrendsReceived
                , Api.getSourceHealth token SourceHealthReceived
                , Api.getEnrichmentGaps token EnrichmentGapsReceived
                ]
            )

        Nothing ->
            ( { dashboard = NotAsked
              , qualityTrends = NotAsked
              , sourceHealth = NotAsked
              , enrichmentGaps = NotAsked
              }
            , Cmd.none
            )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        DashboardReceived result ->
            case result of
                Ok data ->
                    ( { model | dashboard = Success data }, Cmd.none )

                Err err ->
                    ( { model | dashboard = Failure err }, Cmd.none )

        QualityTrendsReceived result ->
            case result of
                Ok data ->
                    ( { model | qualityTrends = Success data }, Cmd.none )

                Err err ->
                    ( { model | qualityTrends = Failure err }, Cmd.none )

        SourceHealthReceived result ->
            case result of
                Ok data ->
                    ( { model | sourceHealth = Success data }, Cmd.none )

                Err err ->
                    ( { model | sourceHealth = Failure err }, Cmd.none )

        EnrichmentGapsReceived result ->
            case result of
                Ok data ->
                    ( { model | enrichmentGaps = Success data }, Cmd.none )

                Err err ->
                    ( { model | enrichmentGaps = Failure err }, Cmd.none )



-- VIEW


view : Model -> Html Msg
view model =
    div [ class "page page--admin metrics-dashboard" ]
        [ h1 [ class "page__title admin__title" ] [ text "Metrics Dashboard" ]
        , p [ class "admin__subtitle" ]
            [ text "The curator's desk: a view of the collection's health." ]
        , viewSourceHealthSection model.sourceHealth
        , viewDataQualitySection model.dashboard model.qualityTrends
        , viewEnrichmentGapsSection model.enrichmentGaps
        , viewCostTrackingSection model.dashboard
        , viewGdprSection model.dashboard
        , viewPhilosophy
        ]


viewSourceHealthSection : RemoteData Http.Error (List SourceHealth) -> Html Msg
viewSourceHealthSection remoteHealth =
    div [ class "metrics-section" ]
        [ h2 [ class "metrics-section__title" ] [ text "Source Health" ]
        , case remoteHealth of
            NotAsked ->
                text ""

            Loading ->
                div [ class "loading" ] [ text "Loading source health..." ]

            Failure _ ->
                p [ class "error" ] [ text "Failed to load source health." ]

            Success sources ->
                if List.isEmpty sources then
                    p [ class "admin__empty" ] [ text "No sources configured." ]

                else
                    table [ class "metrics-table" ]
                        [ thead []
                            [ tr []
                                [ th [] [ text "Source" ]
                                , th [] [ text "Type" ]
                                , th [] [ text "Status" ]
                                , th [] [ text "Consecutive Failures" ]
                                ]
                            ]
                        , tbody []
                            (List.map viewSourceHealthRow sources)
                        ]
        ]


viewSourceHealthRow : SourceHealth -> Html Msg
viewSourceHealthRow source =
    tr []
        [ td [] [ text source.name ]
        , td [] [ text source.sourceType ]
        , td [] [ viewStatusBadge source.status ]
        , td [] [ text (String.fromInt source.consecutiveFailures) ]
        ]


viewStatusBadge : String -> Html Msg
viewStatusBadge status =
    let
        badgeClass =
            case status of
                "healthy" ->
                    "status-badge--healthy"

                "degraded" ->
                    "status-badge--degraded"

                "broken" ->
                    "status-badge--broken"

                _ ->
                    ""
    in
    span [ class ("status-badge " ++ badgeClass) ] [ text status ]


viewDataQualitySection : RemoteData Http.Error MetricsDashboard -> RemoteData Http.Error QualityTrends -> Html Msg
viewDataQualitySection remoteDashboard remoteTrends =
    div [ class "metrics-section" ]
        [ h2 [ class "metrics-section__title" ] [ text "Data Quality" ]
        , case remoteDashboard of
            NotAsked ->
                text ""

            Loading ->
                div [ class "loading" ] [ text "Loading quality data..." ]

            Failure _ ->
                p [ class "error" ] [ text "Failed to load quality data." ]

            Success dashboard ->
                let
                    trendIndicator field =
                        case remoteTrends of
                            Success trends ->
                                trendArrow (field trends)

                            _ ->
                                ""
                in
                div [ class "metrics-cards" ]
                    [ viewQualityCard "Cover Coverage" dashboard.coverPercentage (trendIndicator .coverTrend)
                    , viewQualityCard "Price Coverage" dashboard.pricePercentage (trendIndicator .priceTrend)
                    , viewQualityCard "Review Coverage" dashboard.reviewPercentage (trendIndicator .reviewTrend)
                    ]
        ]


viewQualityCard : String -> Float -> String -> Html Msg
viewQualityCard label percentage trend =
    div [ class "metrics-card" ]
        [ p [ class "metrics-card__label" ] [ text label ]
        , p [ class "metrics-card__value" ]
            [ text (formatPercentage percentage)
            , if String.isEmpty trend then
                text ""

              else
                span [ class "metrics-card__trend" ] [ text (" " ++ trend) ]
            ]
        ]


viewEnrichmentGapsSection : RemoteData Http.Error EnrichmentGaps -> Html Msg
viewEnrichmentGapsSection remoteGaps =
    div [ class "metrics-section" ]
        [ h2 [ class "metrics-section__title" ] [ text "Enrichment Gaps" ]
        , case remoteGaps of
            NotAsked ->
                text ""

            Loading ->
                div [ class "loading" ] [ text "Loading enrichment data..." ]

            Failure _ ->
                p [ class "error" ] [ text "Failed to load enrichment gaps." ]

            Success gaps ->
                div [ class "metrics-cards" ]
                    [ viewGapCard "Without Prices" gaps.booksWithoutPrices
                    , viewGapCard "Without Covers" gaps.booksWithoutCovers
                    , viewGapCard "Without Reviews" gaps.booksWithoutReviews
                    ]
        ]


viewGapCard : String -> Int -> Html Msg
viewGapCard label count =
    div [ class "metrics-card" ]
        [ p [ class "metrics-card__value" ] [ text (String.fromInt count) ]
        , p [ class "metrics-card__label" ] [ text ("books " ++ String.toLower label) ]
        ]


viewCostTrackingSection : RemoteData Http.Error MetricsDashboard -> Html Msg
viewCostTrackingSection remoteDashboard =
    div [ class "metrics-section" ]
        [ h2 [ class "metrics-section__title" ] [ text "Cost Tracking" ]
        , case remoteDashboard of
            NotAsked ->
                text ""

            Loading ->
                div [ class "loading" ] [ text "Loading cost data..." ]

            Failure _ ->
                p [ class "error" ] [ text "Failed to load cost data." ]

            Success dashboard ->
                if List.isEmpty dashboard.costs then
                    p [ class "admin__empty" ] [ text "No cost data available." ]

                else
                    table [ class "metrics-table" ]
                        [ thead []
                            [ tr []
                                [ th [] [ text "Service" ]
                                , th [] [ text "Category" ]
                                , th [] [ text "Amount (ZAR)" ]
                                ]
                            ]
                        , tbody []
                            (List.map viewCostRow dashboard.costs)
                        ]
        ]


viewCostRow : { name : String, category : String, amountZar : Int } -> Html Msg
viewCostRow cost =
    tr []
        [ td [] [ text cost.name ]
        , td [] [ text cost.category ]
        , td [] [ text (formatZar cost.amountZar) ]
        ]


viewGdprSection : RemoteData Http.Error MetricsDashboard -> Html Msg
viewGdprSection remoteDashboard =
    div [ class "metrics-section" ]
        [ h2 [ class "metrics-section__title" ] [ text "GDPR" ]
        , case remoteDashboard of
            NotAsked ->
                text ""

            Loading ->
                div [ class "loading" ] [ text "Loading GDPR data..." ]

            Failure _ ->
                p [ class "error" ] [ text "Failed to load GDPR data." ]

            Success dashboard ->
                div [ class "metrics-cards" ]
                    [ div [ class "metrics-card" ]
                        [ p [ class "metrics-card__value" ] [ text (String.fromInt dashboard.gdprImagesPending) ]
                        , p [ class "metrics-card__label" ] [ text "images pending deletion" ]
                        ]
                    ]
        ]


viewPhilosophy : Html Msg
viewPhilosophy =
    div [ class "metrics-philosophy" ]
        [ p [ class "metrics-philosophy__text" ]
            [ text "Every number here represents a book loved, a connection made, or a gap waiting to be filled. We measure so that we may better serve the collection and the people who tend it." ]
        ]



-- HELPERS


trendArrow : String -> String
trendArrow trend =
    case trend of
        "up" ->
            "↑"

        "down" ->
            "↓"

        "stable" ->
            "→"

        _ ->
            ""


formatPercentage : Float -> String
formatPercentage pct =
    let
        rounded =
            toFloat (round (pct * 10)) / 10
    in
    String.fromFloat rounded ++ "%"


formatZar : Int -> String
formatZar cents =
    let
        rands =
            toFloat cents / 100

        rounded =
            toFloat (round (rands * 100)) / 100
    in
    "R " ++ String.fromFloat rounded
