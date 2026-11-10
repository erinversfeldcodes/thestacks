module Page.CostTransparency exposing
    ( Model
    , Msg(..)
    , costBreakdownDecoder
    , init
    , update
    , view
    )

{-| Public cost-transparency page: aggregate infrastructure costs with
consumer-friendly explanations; no auth, no user data. Follows the
5-layer model — total, story-driven breakdown, per-service cards, real
usage metrics, sustainability footer.
-}

import Api
import Html exposing (Html, div, h1, h2, h3, p, span, text)
import Html.Attributes exposing (class)
import Http
import Json.Decode as Decode exposing (Decoder)
import Stacks.Api.V1.Admin as ProtoAdmin
import Types.ProtoHelpers exposing (emptyToNothing)
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


type alias CostItem =
    { service : String
    , description : Maybe String
    , amountCents : Int

    -- ⛔ `basis` IS WHAT STOPS THIS PAGE LYING. `amountCents` alone cannot say
    -- whether a 0 is a measurement, a free tier's published price, or a figure
    -- nobody has — and five cost-item builders answered an unavailable
    -- measurement with 0, so this page rendered "$0.00" for services it had no
    -- measurement of, under a closing line claiming every number was real.
    --
    -- ⚖️ A rate-card ZERO is honest; only `CostBasisAbsent` means the amount
    -- must not be rendered as money.
    , basis : ProtoAdmin.CostBasis
    , refreshedAt : String
    }


type alias CostCategory =
    { category : String
    , totalCents : Int

    -- ⛔ How many lines in this category have NO figure. The total above
    -- excludes them, so without this the header would quietly under-report and
    -- look complete — which is the same shape as the $0.00 it replaces.
    , unmeasuredCount : Int
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


type Msg
    = CostsReceived (Result Http.Error CostBreakdown)


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        CostsReceived result ->
            ( { model | costs = Types.RemoteData.fromResult result }
            , Cmd.none
            )


{-| `Http.request` rather than the shorter `Http.get`, because `Http.get` has no
`timeout` field at all — it is `Nothing` by construction, i.e. wait forever. The extra four lines are what buys this page a reachable `Failure`
branch.
-}
fetchCosts : Cmd Msg
fetchCosts =
    Http.request
        { method = "GET"
        , headers = []
        , url = "/api/costs"
        , body = Http.emptyBody
        , expect = Http.expectJson CostsReceived costBreakdownDecoder
        , timeout = Api.standardTimeout
        , tracker = Nothing
        }


{-| Adapter: proto CostBreakdown -> app CostBreakdown.
-}
fromProtoCostBreakdown : ProtoAdmin.CostBreakdown -> CostBreakdown
fromProtoCostBreakdown proto =
    { totalCents = proto.totalCents
    , currency = proto.currency
    , costPerBook = proto.costPerBook
    , categories = List.map fromProtoCostCategory proto.categories
    , metrics = fromProtoUsageMetrics proto.metrics
    , monthlyTotals = List.map fromProtoMonthlyTotal proto.monthlyTotals
    , generatedAt = proto.generatedAt
    }


fromProtoCostCategory : ProtoAdmin.CostCategory -> CostCategory
fromProtoCostCategory proto =
    { category = proto.category
    , totalCents = proto.totalCents
    , unmeasuredCount = proto.unmeasuredCount
    , items = List.map fromProtoCostItem proto.items
    }


fromProtoCostItem : ProtoAdmin.CostItem -> CostItem
fromProtoCostItem proto =
    { service = proto.service
    , description = emptyToNothing proto.description
    , amountCents = proto.amountCents
    , basis = proto.basis
    , refreshedAt = proto.refreshedAt
    }


fromProtoUsageMetrics : ProtoAdmin.UsageMetrics -> Metrics
fromProtoUsageMetrics proto =
    { books = proto.books
    , uploads = proto.uploads
    , placements = proto.placements
    , dbSizeBytes = proto.dbSizeBytes
    , avgUploadPayloadBytes = proto.avgUploadPayloadBytes
    , visionJobsThisMonth = proto.visionJobsThisMonth
    }


fromProtoMonthlyTotal : ProtoAdmin.MonthlyTotal -> MonthlyTotal
fromProtoMonthlyTotal proto =
    { periodStart = proto.periodStart
    , periodEnd = proto.periodEnd
    , totalCents = proto.totalCents
    }


costBreakdownDecoder : Decoder CostBreakdown
costBreakdownDecoder =
    Decode.field "data"
        (Decode.map fromProtoCostBreakdown ProtoAdmin.decodeCostBreakdown)


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
    div [ class "costs__content", testId "costs-content" ]
        [ viewTotalBanner breakdown
        , viewStorySection breakdown
        , viewCategoryCards breakdown.categories
        , viewMonthlyTrend breakdown.monthlyTotals
        , viewPhilosophy
        ]


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
                (categoryTotalText (categoryFor "compute" breakdown.categories))
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
                (categoryTotalText (categoryFor "database" breakdown.categories))
            , viewStoryCard "Serve & Browse"
                ("The app runs on a small VM in Virginia (IAD). Every page load, "
                    ++ "API call, and shelf browse is served from here. The vision "
                    ++ "sidecar proxies GPU requests via HMAC-authenticated HTTPS."
                )
                (categoryTotalText (categoryFor "hosting" breakdown.categories))
            ]
        ]


{-| ⛔ TAKES THE RENDERED TEXT, NOT AN INT, because an int cannot say "and one
line we could not measure". These three cards are the most prominent figures on
the page, and they were printing `$0.00/mo` for categories whose lines are
unmeasured — the same false claim as the header, on the cards a reader sees
first.
-}
viewStoryCard : String -> String -> String -> Html Msg
viewStoryCard title narrative costText =
    div [ class "costs__story-card" ]
        [ h3 [ class "costs__story-title" ] [ text title ]
        , p [ class "costs__story-text" ] [ text narrative ]
        , span [ class "costs__story-cost" ] [ text (costText ++ "/mo") ]
        ]


viewCategoryCards : List CostCategory -> Html Msg
viewCategoryCards categories =
    div [ class "costs__categories" ]
        [ h2 [ class "costs__section-title" ] [ text "By Service" ]
        , div [ class "costs__category-grid" ]
            (List.map viewCategoryCard categories)
        ]


viewCategoryCard : CostCategory -> Html Msg
viewCategoryCard cat =
    div [ class "costs__category-card", testId "costs-category-card" ]
        [ div [ class "costs__category-header" ]
            [ h3 [ class "costs__category-name" ] [ text (formatCategoryName cat.category) ]
            , span [ class "costs__category-total" ] [ text (categoryTotalText cat) ]
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
        , div [ class (amountClass item) ] [ amountText item ]
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


{-| The page's closing statement about its own honesty.

⛔ IT USED TO SAY "EVERY NUMBER ON THIS PAGE IS REAL … NOT ESTIMATES OR
PROJECTIONS", AND THAT WAS FALSE IN TWO DIRECTIONS AT ONCE. Most lines are
computed from a published rate card times an observed quantity — which is
honest arithmetic and _is_ an estimate of spend, since a provider's invoice may
differ. And five cost-item builders answered an unavailable measurement with
zero, so the page rendered "$0.00" for services it had no measurement of, under
that very sentence.

⚖️ Replaced rather than removed, because the page's purpose is the claim. What
it can honestly say is now true per line and verifiable by the reader against
the basis shown beside each figure — which is a stronger statement than the
blanket one, not a weaker one: a claim you can check beats a claim you must
take on trust.

-}
viewPhilosophy : Html Msg
viewPhilosophy =
    div [ class "costs__philosophy" ]
        [ p [ class "costs__philosophy-text" ]
            [ text
                ("Each line above says how its figure was arrived at: measured "
                    ++ "from a meter, computed from a published price, or not yet "
                    ++ "measured this period. The Stacks is source-available and "
                    ++ "maintainer-funded; this page exists because we believe you "
                    ++ "should know exactly what it costs to run this platform."
                )
            ]
        ]


{-| The amount cell's class, marking the unmeasured case.

⚖️ A sentence explaining why there is no figure should not be dressed as a
figure. The modifier drops the mono face and the emphasis so a reader can tell
at a glance which lines carry a number — which is the whole point of the basis
field, carried into the visual register rather than left to the words alone.

-}
amountClass : CostItem -> String
amountClass item =
    case item.basis of
        ProtoAdmin.CostBasisAbsent ->
            "costs__service-amount costs__service-amount--unmeasured"

        ProtoAdmin.CostBasisUnspecified ->
            "costs__service-amount costs__service-amount--unmeasured"

        ProtoAdmin.CostBasisMeasured ->
            "costs__service-amount"

        ProtoAdmin.CostBasisRateCard ->
            "costs__service-amount"


{-| The amount, or a sentence saying there is none.

⛔ A figure the page does not have must not look like money. `CostBasisAbsent`
means the meter returned no samples or the store could not be read, and the
caller's own nil path already said so ("a measurement we could not take is nil,
never 0 … a transparency page printing '0' would be claiming the service went
unused") — this is that sentence reaching the reader instead of a $0.00.

⚖️ `Unspecified` is treated as absent rather than as a measurement: an unset
basis on a line carrying a number is exactly the ambiguity the field removes, so
the safe reading is the one that does not assert a figure.

⚠️ The refresh date is shown only when there IS one. A date beside "not yet
measured" would imply the absence itself was measured then.

-}
amountText : CostItem -> Html msg
amountText item =
    case item.basis of
        ProtoAdmin.CostBasisAbsent ->
            text (absentCopy item.refreshedAt)

        ProtoAdmin.CostBasisUnspecified ->
            text (absentCopy item.refreshedAt)

        ProtoAdmin.CostBasisMeasured ->
            text (formatCents item.amountCents)

        ProtoAdmin.CostBasisRateCard ->
            text (formatCents item.amountCents)


absentCopy : String -> String
absentCopy refreshedAt =
    if String.isEmpty refreshedAt then
        "not yet measured this period"

    else
        "not yet measured this period — last refresh " ++ String.left 10 refreshedAt


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


{-| A category's subtotal, saying when it is incomplete.

⛔ THE HEADER USED TO SUM ABSENT LINES AS MONEY. The per-line fix landed and
this did not, so on a live stack "Compute" printed `$0.00` over one measured
line and one unmeasured one — the same false claim the basis field removes at
the line, at the altitude most readers stop at.

⚖️ The subtotal is still shown rather than withheld: a category with two
measured lines and one absent one has a defensible figure, it is merely
incomplete. Saying "this much, and one line we could not measure" tells the
reader more than either a bare number or nothing.

-}
categoryTotalText : CostCategory -> String
categoryTotalText cat =
    if cat.unmeasuredCount == 0 then
        formatCents cat.totalCents

    else if cat.unmeasuredCount == 1 then
        formatCents cat.totalCents ++ " + 1 unmeasured"

    else
        formatCents cat.totalCents
            ++ " + "
            ++ String.fromInt cat.unmeasuredCount
            ++ " unmeasured"


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

        "services" ->
            "Services"

        other ->
            other


{-| The category by name, collapsed to one record.

⚖️ Returns a record rather than an Int so callers can report incompleteness.
The previous `categoryTotal` summed `.totalCents` and discarded the unmeasured
count, which is how the story cards kept printing a bare `$0.00/mo` after the
header had learned not to.

-}
categoryFor : String -> List CostCategory -> CostCategory
categoryFor name categories =
    let
        matching =
            List.filter (\c -> c.category == name) categories
    in
    { category = name
    , totalCents = matching |> List.map .totalCents |> List.sum
    , unmeasuredCount = matching |> List.map .unmeasuredCount |> List.sum
    , items = List.concatMap .items matching
    }
