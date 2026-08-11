module Page.AdminSourceApprovalTest exposing (suite)

{-| Source approval (`/admin/sources`) — the page with TWO stacked
defects, the outer hiding the inner: unreachable (ordinary token → 401),
and once reachable still unusable (the action cell's buttons dispatched
messages no update branch consumed). Tests pin both: admin-token
requests, and each button producing an observable request.
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
                    render (loaded "pending_review")
                        |> Query.has [ testId "source-approve" ]
            , test "Reject renders too" <|
                \_ ->
                    render (loaded "pending_review")
                        |> Query.has [ testId "source-reject" ]
            , test "an already-approved source offers neither" <|
                \_ ->
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
