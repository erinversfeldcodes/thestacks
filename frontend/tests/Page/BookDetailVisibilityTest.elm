module Page.BookDetailVisibilityTest exposing (suite)

{-| Program tests for the per-placement visibility dropdown in the book-detail
overlay (US-10.2.2 — Override Placement Visibility).

Covers:

  - the dropdown renders when the user owns a placement,
  - options that exceed the parent shelf ceiling are greyed out (client-side
    mirror of the server 422),
  - selecting an allowed visibility fires the PUT and, on success, records the
    new value,
  - a server error (e.g. a 422 ceiling rejection that slips past the client
    guard) surfaces a failure message.

-}

import Dict
import Html.Attributes
import Http
import Page.BookDetail as BookDetail
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers
    exposing
        ( bookDetailProgram
        , simulateBookDetailResponseWithVisibility
        , simulatePlacementVisibilityResponse
        , testBook
        )


start : ProgramTest.ProgramTest BookDetail.Model BookDetail.Msg (ProgramTest.SimulatedEffect BookDetail.Msg)
start =
    ProgramTest.start () (bookDetailProgram "book-test-001" (Just "test-token"))


{-| Load a placement whose current visibility is "platform" on a shelf whose
ceiling is also "platform".
-}
loadPlatformPlacement :
    ProgramTest.ProgramTest BookDetail.Model BookDetail.Msg (ProgramTest.SimulatedEffect BookDetail.Msg)
    -> ProgramTest.ProgramTest BookDetail.Model BookDetail.Msg (ProgramTest.SimulatedEffect BookDetail.Msg)
loadPlatformPlacement program =
    program
        |> ProgramTest.simulateHttpResponse "GET"
            "/api/books/book-test-001"
            (simulateBookDetailResponseWithVisibility "book-test-001" testBook "platform" "platform")


suite : Test
suite =
    describe "Page.BookDetail placement visibility (ProgramTest)"
        [ dropdownRenders
        , ceilingExceededOptionDisabled
        , selectFiresUpdateAndRecordsValue
        , serverErrorShowsFailure
        , ceilingHelperTextShown
        , optimisticRollbackOnError
        ]


dropdownRenders : Test
dropdownRenders =
    test "dropdown_renders: owner with a placement sees the visibility control" <|
        \() ->
            start
                |> loadPlatformPlacement
                |> ProgramTest.expectViewHas
                    [ Selector.id "placement-visibility-select" ]


ceilingExceededOptionDisabled : Test
ceilingExceededOptionDisabled =
    test "ceiling_greying: an option more permissive than the shelf ceiling is disabled" <|
        \() ->
            start
                |> loadPlatformPlacement
                |> ProgramTest.expectView
                    (\view ->
                        view
                            |> Query.find
                                [ Selector.tag "option"
                                , Selector.attribute (Html.Attributes.value "public")
                                ]
                            |> Query.has [ Selector.disabled True ]
                    )


selectFiresUpdateAndRecordsValue : Test
selectFiresUpdateAndRecordsValue =
    test "select_saves: choosing an allowed visibility PUTs and records success" <|
        \() ->
            start
                |> loadPlatformPlacement
                |> ProgramTest.selectOption "placement-visibility-select" "Visibility" "owner" "Only me"
                |> ProgramTest.simulateHttpResponse "PUT"
                    "/api/placements/placement-vis-001/visibility"
                    (simulatePlacementVisibilityResponse "placement-vis-001" "owner")
                |> ProgramTest.expectViewHas
                    [ Selector.text "Visibility saved." ]


serverErrorShowsFailure : Test
serverErrorShowsFailure =
    test "server_error: a 422 ceiling rejection surfaces a warm failure message" <|
        \() ->
            start
                |> loadPlatformPlacement
                |> ProgramTest.selectOption "placement-visibility-select" "Visibility" "owner" "Only me"
                |> ProgramTest.simulateHttpResponse "PUT"
                    "/api/placements/placement-vis-001/visibility"
                    (Http.BadStatus_
                        { url = "/api/placements/placement-vis-001/visibility"
                        , statusCode = 422
                        , statusText = "Unprocessable Entity"
                        , headers = Dict.empty
                        }
                        "{\"error\":\"placement cannot be more visible than its shelf\"}"
                    )
                |> ProgramTest.expectViewHas
                    [ Selector.text "We couldn't save that change. Please try again." ]


ceilingHelperTextShown : Test
ceilingHelperTextShown =
    test "helper_text: a restricting shelf ceiling shows always-visible helper text" <|
        \() ->
            start
                |> loadPlatformPlacement
                |> ProgramTest.expectViewHas
                    [ Selector.text "This shelf is set to Members" ]


optimisticRollbackOnError : Test
optimisticRollbackOnError =
    test "rollback: a failed save reverts the select to the prior visibility" <|
        \() ->
            start
                |> loadPlatformPlacement
                |> ProgramTest.selectOption "placement-visibility-select" "Visibility" "owner" "Only me"
                |> ProgramTest.simulateHttpResponse "PUT"
                    "/api/placements/placement-vis-001/visibility"
                    (Http.BadStatus_
                        { url = "/api/placements/placement-vis-001/visibility"
                        , statusCode = 422
                        , statusText = "Unprocessable Entity"
                        , headers = Dict.empty
                        }
                        "{\"error\":\"placement cannot be more visible than its shelf\"}"
                    )
                |> ProgramTest.expectView
                    (\view ->
                        view
                            |> Query.find
                                [ Selector.tag "option"
                                , Selector.attribute (Html.Attributes.value "platform")
                                ]
                            |> Query.has [ Selector.attribute (Html.Attributes.selected True) ]
                    )
