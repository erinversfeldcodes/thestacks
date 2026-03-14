module Page.CostTransparency exposing
    ( Model
    , Msg(..)
    , costBreakdownDecoder
    , init
    , update
    , view
    )

{-| Public cost transparency page.

Displays the platform's infrastructure costs with consumer-friendly
explanations. No authentication required. All data is aggregate
operational costs — no user data is ever exposed.

Follows the 5-layer model from the cost transparency research:

1.  Total at the top (the human number)
2.  Story-driven breakdown (what happens when you use the app)
3.  Per-service detail (expandable category cards)
4.  Real usage metrics from the database
5.  Monthly trend over time

-}

import Html exposing (Html, div, h1, h2, h3, p, span, text)
import Html.Attributes exposing (class)
import Http
import Json.Decode as Decode exposing (Decoder)
import Types.RemoteData exposing (RemoteData(..))



-- MODEL


type alias CostItem =
    { service : String
    , description : Maybe String
    , amountCents : Int
    }


type alias CostCategory =
    { category : String
    , totalCents : Int
    , items : List CostItem
    }


type alias Metrics =
    { books : Int
    , uploads : Int
    , placements : Int
    , dbSizeBytes : Int
    , avgUploadPayloadBytes : Int
    , visionJobsThisMonth : Int
    }


type alias MonthlyTotal =
    { periodStart : String
    , periodEnd : String
    , totalCents : Int
    }


type alias CostBreakdown =
    { totalCents : Int
    , currency : String
    , costPerBook : Float
    , categories : List CostCategory
    , metrics : Metrics
    , monthlyTotals : List MonthlyTotal
    , generatedAt : String
    }


type alias Model =
    { costs : RemoteData Http.Error CostBreakdown
    }


init : ( Model, Cmd Msg )
init =
    ( { costs = Loading }
    , fetchCosts
    )



-- UPDATE


type Msg
    = CostsReceived (Result Http.Error CostBreakdown)


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        CostsReceived result ->
            ( { model | costs = Types.RemoteData.fromResult result }
            , Cmd.none
            )



-- HTTP


fetchCosts : Cmd Msg
fetchCosts =
    Http.get
        { url = "/api/costs"
        , expect = Http.expectJson CostsReceived costBreakdownDecoder
        }


costBreakdownDecoder : Decoder CostBreakdown
costBreakdownDecoder =
    Decode.field "data"
        (Decode.map7 CostBreakdown
            (Decode.field "total_cents" Decode.int)
            (Decode.field "currency" Decode.string)
            (Decode.field "cost_per_book" Decode.float)
            (Decode.field "categories" (Decode.list categoryDecoder))
            (Decode.field "metrics" metricsDecoder)
            (Decode.field "monthly_totals" (Decode.list monthlyTotalDecoder))
            (Decode.field "generated_at" Decode.string)
        )


categoryDecoder : Decoder CostCategory
categoryDecoder =
    Decode.map3 CostCategory
        (Decode.field "category" Decode.string)
        (Decode.field "total_cents" Decode.int)
        (Decode.field "items" (Decode.list costItemDecoder))


costItemDecoder : Decoder CostItem
costItemDecoder =
    Decode.map3 CostItem
        (Decode.field "service" Decode.string)
        (Decode.maybe (Decode.field "description" Decode.string))
        (Decode.field "amount_cents" Decode.int)


metricsDecoder : Decoder Metrics
metricsDecoder =
    Decode.map6 Metrics
        (Decode.field "books" Decode.int)
        (Decode.field "uploads" Decode.int)
        (Decode.field "placements" Decode.int)
        (Decode.field "db_size_bytes" Decode.int)
        (Decode.field "avg_upload_payload_bytes" Decode.int)
        (Decode.field "vision_jobs_this_month" Decode.int)


monthlyTotalDecoder : Decoder MonthlyTotal
monthlyTotalDecoder =
    Decode.map3 MonthlyTotal
        (Decode.field "period_start" Decode.string)
        (Decode.field "period_end" Decode.string)
        (Decode.field "total_cents" Decode.int)



-- VIEW


view : Model -> Html Msg
view model =
    div [ class "page page--costs curator-desk" ]
        [ h1 [ class "page__title costs__title" ] [ text "Cost Transparency" ]
        , p [ class "costs__subtitle" ]
            [ text "An honest look at what it costs to run The Stacks." ]
        , case model.costs of
            NotAsked ->
                text ""

            Loading ->
                div [ class "loading" ] [ text "Loading cost data..." ]

            Failure _ ->
                p [ class "error" ] [ text "Failed to load cost data. Please try again later." ]

            Success breakdown ->
                viewBreakdown breakdown
        ]


viewBreakdown : CostBreakdown -> Html Msg
viewBreakdown breakdown =
    div [ class "costs__content" ]
        [ viewTotalBanner breakdown
        , viewStorySection breakdown
        , viewCategoryCards breakdown.categories
        , viewMonthlyTrend breakdown.monthlyTotals
        , viewPhilosophy
        ]



-- LAYER 1: The Human Number


viewTotalBanner : CostBreakdown -> Html Msg
viewTotalBanner breakdown =
    div [ class "costs__banner" ]
        [ div [ class "costs__banner-total" ]
            [ span [ class "costs__banner-label" ] [ text "Total monthly cost" ]
            , span [ class "costs__banner-amount" ] [ text (formatCents breakdown.totalCents) ]
            ]
        , div [ class "costs__banner-formula" ]
            (breakdown.categories
                |> List.map
                    (\cat ->
                        span [ class "costs__banner-term" ]
                            [ text (formatCategoryName cat.category ++ " " ++ formatCents cat.totalCents) ]
                    )
                |> List.intersperse (span [ class "costs__banner-plus" ] [ text " + " ])
            )
        ]



-- LAYER 2: Story-driven breakdown


viewStorySection : CostBreakdown -> Html Msg
viewStorySection breakdown =
    let
        m =
            breakdown.metrics
    in
    div [ class "costs__stories" ]
        [ h2 [ class "costs__section-title" ] [ text "Where Your Data Lives" ]
        , div [ class "costs__story-grid" ]
            [ viewStoryCard "Upload & Identify"
                ("When you photograph a book, we send the image to a vision model on a GPU. "
                    ++ "It reads the title, author, and ISBN, then we verify against Open Library. "
                    ++ String.fromInt m.visionJobsThisMonth
                    ++ " identifications this month."
                )
                (categoryTotal "compute" breakdown.categories)
            , viewStoryCard "Store & Shelve"
                ("Each book has metadata — title, author, ISBN, cover URL — plus your "
                    ++ "placement on a shelf. "
                    ++ String.fromInt m.books
                    ++ " books catalogued, "
                    ++ String.fromInt m.placements
                    ++ " shelf placements. Database: "
                    ++ formatBytes m.dbSizeBytes
                    ++ "."
                )
                (categoryTotal "database" breakdown.categories)
            , viewStoryCard "Serve & Browse"
                ("The app runs on a small VM in Virginia (IAD). Every page load, "
                    ++ "API call, and shelf browse is served from here. The vision "
                    ++ "sidecar proxies GPU requests via HMAC-authenticated HTTPS."
                )
                (categoryTotal "hosting" breakdown.categories)
            ]
        ]


viewStoryCard : String -> String -> Int -> Html Msg
viewStoryCard title narrative cents =
    div [ class "costs__story-card" ]
        [ h3 [ class "costs__story-title" ] [ text title ]
        , p [ class "costs__story-text" ] [ text narrative ]
        , span [ class "costs__story-cost" ] [ text (formatCents cents ++ "/mo") ]
        ]



-- LAYER 3: Per-service detail


viewCategoryCards : List CostCategory -> Html Msg
viewCategoryCards categories =
    div [ class "costs__categories" ]
        [ h2 [ class "costs__section-title" ] [ text "By Service" ]
        , div [ class "costs__category-grid" ]
            (List.map viewCategoryCard categories)
        ]


viewCategoryCard : CostCategory -> Html Msg
viewCategoryCard cat =
    div [ class "costs__category-card" ]
        [ div [ class "costs__category-header" ]
            [ h3 [ class "costs__category-name" ] [ text (formatCategoryName cat.category) ]
            , span [ class "costs__category-total" ] [ text (formatCents cat.totalCents) ]
            ]
        , div [ class "costs__category-items" ]
            (List.map viewServiceItem cat.items)
        ]


viewServiceItem : CostItem -> Html Msg
viewServiceItem item =
    div [ class "costs__service-item" ]
        [ div [ class "costs__service-name" ] [ text item.service ]
        , div [ class "costs__service-desc" ]
            [ text (Maybe.withDefault "" item.description) ]
        , div [ class "costs__service-amount" ] [ text (formatCents item.amountCents) ]
        ]



-- LAYER 4: Monthly trend


viewMonthlyTrend : List MonthlyTotal -> Html Msg
viewMonthlyTrend totals =
    if List.isEmpty totals then
        text ""

    else
        let
            maxCents =
                List.map .totalCents totals
                    |> List.maximum
                    |> Maybe.withDefault 1
                    |> max 1
        in
        div [ class "costs__trend" ]
            [ h2 [ class "costs__section-title" ] [ text "Monthly Trend" ]
            , div [ class "costs__chart" ]
                (List.map (viewTrendBar maxCents) totals)
            ]


viewTrendBar : Int -> MonthlyTotal -> Html Msg
viewTrendBar maxCents total =
    let
        pct =
            toFloat total.totalCents / toFloat maxCents * 100.0

        monthLabel =
            String.left 7 total.periodStart
    in
    div [ class "costs__bar-group" ]
        [ div
            [ class "costs__bar"
            , Html.Attributes.style "height" (String.fromFloat pct ++ "%")
            ]
            []
        , span [ class "costs__bar-label" ] [ text monthLabel ]
        , span [ class "costs__bar-amount" ] [ text (formatCents total.totalCents) ]
        ]



-- LAYER 5: Philosophy


viewPhilosophy : Html Msg
viewPhilosophy =
    div [ class "costs__philosophy" ]
        [ p [ class "costs__philosophy-text" ]
            [ text
                ("Every number on this page is real. Costs are computed from "
                    ++ "published rate cards and actual database metrics — not estimates "
                    ++ "or projections. The Stacks is open-source and maintainer-funded; "
                    ++ "this page exists because we believe you should know exactly "
                    ++ "what it costs run this platform."
                )
            ]
        ]



-- HELPERS


formatCents : Int -> String
formatCents cents =
    let
        dollars =
            cents // 100

        remainder =
            modBy 100 cents

        centStr =
            if remainder < 10 then
                "0" ++ String.fromInt remainder

            else
                String.fromInt remainder
    in
    "$" ++ String.fromInt dollars ++ "." ++ centStr


formatBytes : Int -> String
formatBytes bytes =
    if bytes >= 1073741824 then
        String.fromFloat (toFloat bytes / 1073741824 |> roundTo 1) ++ " GB"

    else if bytes >= 1048576 then
        String.fromFloat (toFloat bytes / 1048576 |> roundTo 1) ++ " MB"

    else if bytes >= 1024 then
        String.fromFloat (toFloat bytes / 1024 |> roundTo 1) ++ " KB"

    else
        String.fromInt bytes ++ " B"


roundTo : Int -> Float -> Float
roundTo places value =
    let
        factor =
            toFloat (10 ^ places)
    in
    toFloat (round (value * factor)) / factor


formatCategoryName : String -> String
formatCategoryName category =
    case category of
        "hosting" ->
            "Hosting"

        "compute" ->
            "Compute"

        "database" ->
            "Database"

        "domain" ->
            "Domain"

        other ->
            other


categoryTotal : String -> List CostCategory -> Int
categoryTotal name categories =
    categories
        |> List.filter (\c -> c.category == name)
        |> List.map .totalCents
        |> List.sum
