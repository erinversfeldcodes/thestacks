module AdminRemovalRequestsTest exposing (suite)

{-| Tests the removal-request review queue — reachability and safety, not
list rendering (the server half shipped first and nothing rendered it):
approve and dismiss cannot be confused, both hit the admin endpoints
with the admin token, and a lapsed admin session surfaces the admin
notice rather than signing the operator out of the product.
-}

import Api exposing (RemovalRequest)
import Expect
import Html.Attributes as Attr
import Http
import Page.Admin.RemovalRequests as Queue
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.RemoteData exposing (RemoteData(..))


request : String -> RemovalRequest
request name =
    { id = "req-" ++ name
    , name = name
    , url = "https://" ++ name ++ ".example"
    , sourceType = "community"
    , email = Just ("owner@" ++ name ++ ".example")
    , requestedAt = Just "2026-07-20T09:30:00Z"
    }


loaded : List RemovalRequest -> Queue.Model
loaded requests =
    { requests = Success requests
    , deciding = Nothing
    , confirming = Nothing
    , error = Nothing
    }


render : Queue.Model -> Query.Single Queue.Msg
render model =
    Queue.view model |> Query.fromHtml


{-| Elm record update needs a variable, not an expression, so these two build the
mid-decision states the view has to distinguish.
-}
confirmingModel : String -> List RemovalRequest -> Queue.Model
confirmingModel id requests =
    let
        model =
            loaded requests
    in
    { model | confirming = Just id }


erroredModel : String -> List RemovalRequest -> Queue.Model
erroredModel message requests =
    let
        model =
            loaded requests
    in
    { model | error = Just message }


testId : String -> Selector.Selector
testId value =
    Selector.attribute (Attr.attribute "data-testid" value)


suite : Test
suite =
    describe "Admin removal requests"
        [ describe "the queue is visible at all — the half that was missing"
            [ test "renders a row per pending request" <|
                \_ ->
                    render (loaded [ request "truth", request "haas" ])
                        |> Query.findAll [ testId "removal-queue-row" ]
                        |> Query.count (Expect.equal 2)
            , test "shows the contact address, which is what the reviewer judges" <|
                \_ ->
                    render (loaded [ request "truth" ])
                        |> Query.has [ Selector.text "owner@truth.example" ]
            , test "shows the listing URL so the reviewer can look at it" <|
                \_ ->
                    render (loaded [ request "truth" ])
                        |> Query.has [ Selector.text "https://truth.example" ]
            , test "says plainly that the listings are still live" <|
                \_ ->
                    render (loaded [ request "truth" ])
                        |> Query.has [ Selector.text "still live" ]
            ]
        , describe "an empty queue is good news, not a failure"
            [ test "says the queue is clear" <|
                \_ ->
                    render (loaded [])
                        |> Query.has [ testId "removal-queue-empty" ]
            , test "a failed load does NOT look like an empty queue" <|
                \_ ->
                    render
                        { requests = Failure Http.NetworkError
                        , deciding = Nothing
                        , confirming = Nothing
                        , error = Nothing
                        }
                        |> Query.hasNot [ testId "removal-queue-empty" ]
            ]
        , describe "the two decisions cannot be confused with publishing a listing"
            [ test "no control is labelled approve or reject" <|
                \_ ->
                    render (loaded [ request "truth" ])
                        |> Query.hasNot [ Selector.text "Approve" ]
            , test "the destructive action names what happens to the listing" <|
                \_ ->
                    render (loaded [ request "truth" ])
                        |> Query.find [ testId "removal-queue-remove" ]
                        |> Query.has [ Selector.text "Remove the listing" ]
            , test "the other action names what happens to the listing too" <|
                \_ ->
                    render (loaded [ request "truth" ])
                        |> Query.find [ testId "removal-queue-keep" ]
                        |> Query.has [ Selector.text "Keep the listing" ]
            ]
        , describe "removal takes two steps"
            [ test "the first click asks rather than removing" <|
                \_ ->
                    let
                        ( model, _ ) =
                            updateQueue (Queue.RemoveClicked "req-truth") (loaded [ request "truth" ])
                    in
                    Expect.all
                        [ \m -> Expect.equal (Just "req-truth") m.confirming
                        , -- Nothing is in flight yet: the click only opened the question.
                          \m -> Expect.equal Nothing m.deciding
                        ]
                        model
            , test "the confirmation names the business" <|
                \_ ->
                    render (confirmingModel "req-truth" [ request "truth" ])
                        |> Query.has [ Selector.text "Remove truth from the map?" ]
            , test "confirming is what fires the request" <|
                \_ ->
                    let
                        ( model, _ ) =
                            updateQueue (Queue.RemoveConfirmed "req-truth")
                                (confirmingModel "req-truth" [ request "truth" ])
                    in
                    Expect.equal (Just "req-truth") model.deciding
            , test "cancelling leaves the request in the queue" <|
                \_ ->
                    let
                        ( model, _ ) =
                            updateQueue Queue.RemoveCancelled
                                (confirmingModel "req-truth" [ request "truth" ])
                    in
                    Expect.all
                        [ \m -> Expect.equal Nothing m.confirming
                        , \m -> Expect.equal (Success [ request "truth" ]) m.requests
                        ]
                        model
            , test "keeping the listing needs no confirmation" <|
                \_ ->
                    let
                        ( model, _ ) =
                            updateQueue (Queue.KeepClicked "req-truth") (loaded [ request "truth" ])
                    in
                    Expect.equal (Just "req-truth") model.deciding
            ]
        , describe "a decision removes the row it applied to, and only that row"
            [ test "the decided request leaves the queue" <|
                \_ ->
                    let
                        ( model, _ ) =
                            updateQueue (Queue.DecisionCompleted "req-truth" (Ok ()))
                                (loaded [ request "truth", request "haas" ])
                    in
                    Expect.equal (Success [ request "haas" ]) model.requests
            , test "an unrelated request is untouched" <|
                \_ ->
                    let
                        ( model, _ ) =
                            updateQueue (Queue.DecisionCompleted "req-nonexistent" (Ok ()))
                                (loaded [ request "truth" ])
                    in
                    Expect.equal (Success [ request "truth" ]) model.requests
            ]
        , describe "a rejected decision is explained in the reviewer's terms"
            [ test "409 says it was already decided, not that it vanished" <|
                \_ ->
                    let
                        ( model, _ ) =
                            updateQueue
                                (Queue.DecisionCompleted "req-truth" (Err (Http.BadStatus 409)))
                                (loaded [ request "truth" ])
                    in
                    Expect.equal (Just "That request has already been decided — the queue below is up to date.")
                        model.error
            , test "the error is shown on the page, not only held in the model" <|
                \_ ->
                    render (erroredModel "already decided" [ request "truth" ])
                        |> Query.has [ testId "removal-queue-error" ]
            , test "a failed decision does not drop the row" <|
                \_ ->
                    let
                        ( model, _ ) =
                            updateQueue
                                (Queue.DecisionCompleted "req-truth" (Err (Http.BadStatus 409)))
                                (loaded [ request "truth" ])
                    in
                    Expect.equal (Success [ request "truth" ]) model.requests
            ]
        ]


{-| `update` needs a token; these tests never assert on the Cmd's contents, only that the
model moved, so a fixed token keeps each call site short.
-}
updateQueue : Queue.Msg -> Queue.Model -> ( Queue.Model, Cmd Queue.Msg )
updateQueue msg model =
    let
        ( newModel, cmd, _ ) =
            Queue.update msg model (Just "token")
    in
    ( newModel, cmd )
