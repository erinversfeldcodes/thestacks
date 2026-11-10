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
import Stacks.Common.V1.Costs as ProtoCosts
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
    , basis : ProtoCosts.CostBasis
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
            [ span [ class "costs__banner-label" ] [ text (bannerLabel breakdown) ]
            , span [ class "costs__banner-amount" ] [ text (formatCents breakdown.totalCents) ]
            , span [ class "costs__banner-caveat" ] [ text (totalCaveat breakdown) ]
            ]
        , div [ class "costs__banner-formula" ]
            (breakdown.categories
                |> List.map
                    (\cat ->
                        span [ class "costs__banner-term" ]
                            -- ⛔ THE THIRD PRESENTATION SITE, AND IT WAS MISSED.
                            -- `costs.ex` fixed four aggregation sites and this
                            -- module fixed two of three display sites: the
                            -- category CARD said "$4.88 + 2 unmeasured" while
                            -- this banner, directly above it, said "$0.00" for
                            -- a category whose every line was unmeasured. That
                            -- is exactly the "$0.00 for something we did not
                            -- measure" this whole change exists to delete,
                            -- printed in the largest type on the page above
                            -- the copy that contradicts it.
                            [ text (formatCategoryName cat.category ++ " " ++ categoryTotalText cat) ]
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
                (categoryFor "compute" breakdown.categories)
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
                (categoryFor "database" breakdown.categories)
            , viewStoryCard "Serve & Browse"
                ("The app runs on a small VM in Virginia (IAD). Every page load, "
                    ++ "API call, and shelf browse is served from here. The vision "
                    ++ "sidecar proxies GPU requests via HMAC-authenticated HTTPS."
                )
                (categoryFor "hosting" breakdown.categories)
            ]
        ]


{-| ⛔ TAKES THE RENDERED TEXT, NOT AN INT, because an int cannot say "and one
line we could not measure". These three cards are the most prominent figures on
the page, and they were printing `$0.00/mo` for categories whose lines are
unmeasured — the same false claim as the header, on the cards a reader sees
first.
-}
viewStoryCard : String -> String -> CostCategory -> Html Msg
viewStoryCard title narrative cat =
    div [ class "costs__story-card" ]
        [ h3 [ class "costs__story-title" ] [ text title ]
        , p [ class "costs__story-text" ] [ text narrative ]
        , span [ class "costs__story-cost" ]
            [ text (categoryMoneyText cat ++ "/mo" ++ unmeasuredSuffix cat) ]
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
        ProtoCosts.CostBasisAbsent ->
            "costs__service-amount costs__service-amount--unmeasured"

        ProtoCosts.CostBasisUnspecified ->
            "costs__service-amount costs__service-amount--unmeasured"

        ProtoCosts.CostBasisMeasured ->
            "costs__service-amount"

        ProtoCosts.CostBasisRateCard ->
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
        ProtoCosts.CostBasisAbsent ->
            text (absentCopy item.refreshedAt)

        ProtoCosts.CostBasisUnspecified ->
            text (absentCopy item.refreshedAt)

        ProtoCosts.CostBasisMeasured ->
            text (formatCents item.amountCents)

        ProtoCosts.CostBasisRateCard ->
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
    categoryMoneyText cat ++ unmeasuredSuffix cat


{-| The label, naming the period the figure covers.

⛔ THE PAGE SAID "THIS PERIOD" FIVE TIMES AND NEVER DEFINED IT. Every absent
line reads "not yet measured this period" and the total was labelled "Total
monthly cost", with no date anywhere — so a reader could not tell whether they
were looking at the current month, the last complete one, or something cached.
On a page whose whole claim is that each figure says how it was arrived at,
omitting _when_ leaves the claim half-made.

⚖️ Taken from the items the page already decodes rather than from the client's
clock: `periodStart` is a fact the server asserted about these figures, and a
locally-computed month would silently disagree with them whenever the two
differed — which is exactly the case a reader needs the date for.

-}
bannerLabel : CostBreakdown -> String
bannerLabel breakdown =
    case firstPeriodStart breakdown of
        Just start ->
            "Total cost for " ++ monthLabel start

        Nothing ->
            "Total monthly cost"


firstPeriodStart : CostBreakdown -> Maybe String
firstPeriodStart breakdown =
    breakdown.categories
        |> List.concatMap .items
        |> List.map .periodStart
        |> List.filter (\s -> s /= "")
        |> List.head


{-| `2026-11-01T00:00:00Z` -> `November 2026`. ⚖️ Falls back to the raw string
rather than guessing: a format this does not recognise is better shown verbatim
than rendered as a confidently wrong month.
-}
monthLabel : String -> String
monthLabel iso =
    case String.split "-" (String.left 7 iso) of
        [ year, month ] ->
            case monthName month of
                Just name ->
                    name ++ " " ++ year

                Nothing ->
                    iso

        _ ->
            iso


monthName : String -> Maybe String
monthName month =
    case month of
        "01" ->
            Just "January"

        "02" ->
            Just "February"

        "03" ->
            Just "March"

        "04" ->
            Just "April"

        "05" ->
            Just "May"

        "06" ->
            Just "June"

        "07" ->
            Just "July"

        "08" ->
            Just "August"

        "09" ->
            Just "September"

        "10" ->
            Just "October"

        "11" ->
            Just "November"

        "12" ->
            Just "December"

        _ ->
            Nothing


{-| What the headline figure leaves out, said beside the headline figure.

⛔ THE NUMBER A READER QUOTES WAS THE ONE THAT SILENTLY OMITTED MOST SERVICES.
`TOTAL MONTHLY COST $21.56` was rendered with five of eleven lines excluded and
nothing on the page saying so — so the page's most prominent claim was its least
complete one, under a closing sentence promising that each line says how its
figure was arrived at.

⚖️ Phrased as a count of services rather than a hedge, because "approximately"
tells a reader nothing they can act on while "6 of 11 services measured" tells
them exactly how much of the total they are looking at.

-}
totalCaveat : CostBreakdown -> String
totalCaveat breakdown =
    let
        unmeasured =
            breakdown.categories |> List.map .unmeasuredCount |> List.sum

        lines =
            breakdown.categories |> List.map (.items >> List.length) |> List.sum
    in
    if unmeasured == 0 then
        " — all " ++ String.fromInt lines ++ " services measured"

    else
        " — "
            ++ String.fromInt (lines - unmeasured)
            ++ " of "
            ++ String.fromInt lines
            ++ " services measured; the rest are not yet counted"


{-| Just the money part of a category's figure.

⛔ SEPARATED BECAUSE A UNIT BELONGS TO A NUMBER, NOT TO A SENTENCE. The story
cards render `costText ++ "/mo"`, which was correct while `costText` was a
currency figure — and the moment the aggregate fix made it a sentence, the card
shipped **"$X.XX + 1 unmeasured/mo"** on the most prominent figure on the page.
The `Int -> String` change was the right fix for the aggregate and carried this
with it.

⚖️ So the suffix is composed per-part: the card appends "/mo" to the money and
the unmeasured note trails it, instead of "/mo" landing on whatever the last
word happens to be.

-}
categoryMoneyText : CostCategory -> String
categoryMoneyText cat =
    formatCents cat.totalCents


{-| The trailing note when a category has lines with no figure, or "".
-}
unmeasuredSuffix : CostCategory -> String
unmeasuredSuffix cat =
    if cat.unmeasuredCount == 0 then
        ""

    else if cat.unmeasuredCount == 1 then
        " + 1 unmeasured"

    else
        " + " ++ String.fromInt cat.unmeasuredCount ++ " unmeasured"


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
