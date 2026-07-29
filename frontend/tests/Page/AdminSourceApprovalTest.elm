module Page.AdminSourceApprovalTest exposing (suite)

{-| Source approval (`/admin/sources`).

⚠️ **This page had TWO independent defects stacked, and the outer one hid the inner one.**

1.  It was unreachable at all — it sent the ordinary Guardian token to the `:admin` pipeline, which
    401s anything without an MFA-verified admin session (#303).
2.  Once reachable, it was still unusable: the row's action cell tested `status == "pending"`, but
    the server's value is **`"pending_review"`**, so **Approve and Reject never rendered**. The page
    showed an "Actions" column that was permanently empty.

Nobody could see (2) while (1) was true, which is why fixing the auth alone would have shipped a
page that loads and does nothing. Both were found by driving the deployed preview, not by reading.

The status strings are the whole subject of this module, because the page invented three the server
never uses: `"pending"` (really `pending_review`), `"rejected"` (really `dismissed`), and it only got
`"approved"` right by accident.

-}

import Api exposing (AdminSource)
import Expect
import Html.Attributes as Attr
import Page.Admin.SourceApproval as SourceApproval
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.RemoteData exposing (RemoteData(..))


testId : String -> Selector.Selector
testId value =
    Selector.attribute (Attr.attribute "data-testid" value)


source : String -> AdminSource
source status =
    { id = "src-1"
    , name = "Truth Coffee Roasting"
    , url = "https://truth.coffee"
    , sourceType = "community"
    , status = status
    , confidenceScore = 0.6
    }


loaded : String -> SourceApproval.Model
loaded status =
    { sources =
        Success { sources = [ source status ], total = 1, page = 1, perPage = 20 }
    , statusFilter = SourceApproval.All
    , page = 1
    , actionInProgress = Nothing
    , actionError = Nothing
    }


render : SourceApproval.Model -> Query.Single SourceApproval.Msg
render model =
    SourceApproval.view model |> Query.fromHtml


suite : Test
suite =
    describe "Page.Admin.SourceApproval"
        [ describe "a source awaiting review offers the decisions"
            [ test "Approve renders for the server's real status value" <|
                \_ ->
                    -- ⛔ The bug. `"pending_review"` is what `Stacks.Discovery` writes on create and
                    -- gates both transitions on; the page compared against `"pending"`.
                    render (loaded "pending_review")
                        |> Query.has [ testId "source-approve" ]
            , test "Reject renders too" <|
                \_ ->
                    render (loaded "pending_review")
                        |> Query.has [ testId "source-reject" ]
            , test "an already-approved source offers neither" <|
                \_ ->
                    -- ⚠️ Anchored on the testId, not the word. `Selector.text "Approve"` also matches
                    -- the **"Approved" filter tab**, so a prose version of this assertion passes
                    -- whether the buttons are there or not — #302's defect class, caught here by the
                    -- negative case failing when it should not have.
                    render (loaded "approved")
                        |> Query.hasNot [ testId "source-approve" ]
            , test "a dismissed source offers neither" <|
                \_ ->
                    render (loaded "dismissed")
                        |> Query.hasNot [ testId "source-approve" ]
            ]
        , describe "the status filter sends what the server understands"
            [ test "Pending filters on pending_review, not pending" <|
                \_ ->
                    -- Sending `"pending"` matched no row, so the Pending tab showed an empty list
                    -- and read as "nothing to review" — the worst possible way to be wrong on a
                    -- queue whose entire job is telling you there is something to do.
                    SourceApproval.statusFilterToString SourceApproval.Pending
                        |> Expect.equal (Just "pending_review")
            , test "Rejected filters on dismissed — the server's word, not the UI's" <|
                \_ ->
                    SourceApproval.statusFilterToString SourceApproval.Rejected
                        |> Expect.equal (Just "dismissed")
            , test "Approved was already right" <|
                \_ ->
                    SourceApproval.statusFilterToString SourceApproval.Approved
                        |> Expect.equal (Just "approved")
            , test "All sends no status at all" <|
                \_ ->
                    SourceApproval.statusFilterToString SourceApproval.All
                        |> Expect.equal Nothing
            ]
        , describe "the row still shows what it always showed"
            [ test "name and url are rendered" <|
                \_ ->
                    render (loaded "pending_review")
                        |> Expect.all
                            [ Query.has [ Selector.text "Truth Coffee Roasting" ]
                            , Query.has [ Selector.text "https://truth.coffee" ]
                            ]
            , test "an action in flight disables the buttons" <|
                \_ ->
                    let
                        model =
                            loaded "pending_review"
                    in
                    render { model | actionInProgress = Just "src-1" }
                        |> Query.findAll [ Selector.attribute (Attr.disabled True) ]
                        |> Query.count (Expect.atLeast 1)
            ]
        ]
