module Page.CostTransparency exposing
    ( Model
    , Msg(..)
    , costBreakdownDecoder
    , init
    , update
    , view
    )

{-| Public cost transparency page.

Displays the platform's infrastructure costs in the curator's desk aesthetic.
No authentication required. All data is aggregate operational costs.

-}

import Html exposing (Html, div, h1, h2, h3, p, span, table, tbody, td, text, th, thead, tr)
import Html.Attributes exposing (class)
import Http
import Json.Decode as Decode exposing (Decoder)
import Types.RemoteData exposing (RemoteData(..))



-- MODEL


type alias CostLineItem =
    { category : String
    , service : String
    , description : Maybe String
    , amountCents : Int
    , currency : String
    , periodStart : String
    , periodEnd : String
    }


type alias MonthlyTotal =
    { periodStart : String
    , periodEnd : String
    , totalCents : Int
    }


type alias CostBreakdown =
    { lineItems : List CostLineItem
    , totalCents : Int
    , currency : String
    , costPerBook : Float
    , bookCount : Int
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
            (Decode.field "line_items" (Decode.list costLineItemDecoder))
            (Decode.field "total_cents" Decode.int)
            (Decode.field "currency" Decode.string)
            (Decode.field "cost_per_book" Decode.float)
            (Decode.field "book_count" Decode.int)
            (Decode.field "monthly_totals" (Decode.list monthlyTotalDecoder))
            (Decode.field "generated_at" Decode.string)
        )


costLineItemDecoder : Decoder CostLineItem
costLineItemDecoder =
    Decode.map7 CostLineItem
        (Decode.field "category" Decode.string)
        (Decode.field "service" Decode.string)
        (Decode.maybe (Decode.field "description" Decode.string))
        (Decode.field "amount_cents" Decode.int)
        (Decode.field "currency" Decode.string)
        (Decode.field "period_start" Decode.string)
        (Decode.field "period_end" Decode.string)


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
                div [ class "costs__content" ]
                    [ viewCostTable breakdown
                    , viewTotalSection breakdown
                    , viewMonthlyTrend breakdown.monthlyTotals
                    , viewPhilosophyNote
                    ]
        ]


viewCostTable : CostBreakdown -> Html Msg
viewCostTable breakdown =
    div [ class "costs__ledger" ]
        [ h2 [ class "costs__section-title" ] [ text "Current Period" ]
        , table [ class "costs__table ledger-table" ]
            [ thead []
                [ tr []
                    [ th [ class "ledger-table__th" ] [ text "Category" ]
                    , th [ class "ledger-table__th" ] [ text "Service" ]
                    , th [ class "ledger-table__th" ] [ text "Description" ]
                    , th [ class "ledger-table__th ledger-table__th--amount" ] [ text "Amount" ]
                    ]
                ]
            , tbody []
                (List.map viewCostRow breakdown.lineItems)
            ]
        ]


viewCostRow : CostLineItem -> Html Msg
viewCostRow item =
    tr [ class "ledger-table__row" ]
        [ td [ class "ledger-table__td" ] [ text (formatCategory item.category) ]
        , td [ class "ledger-table__td ledger-table__td--service" ] [ text item.service ]
        , td [ class "ledger-table__td ledger-table__td--description" ]
            [ text (Maybe.withDefault "" item.description) ]
        , td [ class "ledger-table__td ledger-table__td--amount" ]
            [ text (formatCents item.amountCents) ]
        ]


viewTotalSection : CostBreakdown -> Html Msg
viewTotalSection breakdown =
    div [ class "costs__totals" ]
        [ h2 [ class "costs__section-title" ] [ text "Summary" ]
        , div [ class "costs__summary-grid" ]
            [ div [ class "costs__summary-card" ]
                [ h3 [ class "costs__card-label" ] [ text "Monthly Total" ]
                , span [ class "costs__card-value" ]
                    [ text (formatCents breakdown.totalCents) ]
                ]
            , div [ class "costs__summary-card" ]
                [ h3 [ class "costs__card-label" ] [ text "Books in System" ]
                , span [ class "costs__card-value" ]
                    [ text (String.fromInt breakdown.bookCount) ]
                ]
            , div [ class "costs__summary-card" ]
                [ h3 [ class "costs__card-label" ] [ text "Cost per Book" ]
                , span [ class "costs__card-value" ]
                    [ text ("$" ++ String.fromFloat breakdown.costPerBook) ]
                ]
            ]
        ]


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


viewPhilosophyNote : Html Msg
viewPhilosophyNote =
    div [ class "costs__philosophy" ]
        [ p [ class "costs__philosophy-text" ]
            [ text "Every number here is real, unfiltered, and automated." ]
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


formatCategory : String -> String
formatCategory category =
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
