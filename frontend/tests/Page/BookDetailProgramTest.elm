module Page.BookDetailProgramTest exposing (suite)

{-| Program tests for Page.BookDetail using elm-program-test.

These tests exercise the BookDetail page lifecycle through
simulated HTTP responses and user interactions.

-}

import Dict
import Expect
import Html.Attributes
import Http
import Navigation.Route as Route
import Page.BookDetail as BookDetail
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers
    exposing
        ( bookDetailProgram
        , bookDetailProgramWithOut
        , simulateBookDetailResponse
        , simulateBookDetailResponseWithPlacement
        , testBook
        , testPlacement
        )
import Types.RemoteData exposing (RemoteData(..))


{-| Helper to start a book detail program with an auth token.
-}
startBookDetail : ProgramTest.ProgramTest BookDetail.Model BookDetail.Msg (ProgramTest.SimulatedEffect BookDetail.Msg)
startBookDetail =
    ProgramTest.start () (bookDetailProgram "book-test-001" (Just "test-token"))


suite : Test
suite =
    describe "Page.BookDetail (ProgramTest)"
        [ loadingState
        , successRendersAllSections
        , failureRendersError
        , forbiddenTriggersAgeGate
        , formatToggleUpdatesSelected
        , shelfMoverOpenSelectConfirmFlow
        , removeModalOpenConfirmFlow
        , sectionContentDetails
        , placementLoadedShowsCurrentBookshelf
        , ariaRegionsPresent
        , ratingDisplayWithoutPlacement
        , moveConfirmHappyUpdatesBookshelf
        , removeConfirmNavigatesToPreviousRoute
        , removeCompletedErrorShowsMessage
        , confirmMoveNoPlacementIsNoOp
        , confirmMoveNoTokenIsNoOp
        , confirmRemoveNoPlacementIsNoOp
        , confirmRemoveNoTokenIsNoOp
        ]


loadingState : Test
loadingState =
    test "loading_state: before HTTP response arrives, loading indicator is visible" <|
        \() ->
            startBookDetail
                |> ProgramTest.expectViewHas
                    [ Selector.text "Loading book..." ]


successRendersAllSections : Test
successRendersAllSections =
    test "success_renders_all_sections: successful response renders hero, about, reviews, prices, author, writing, shelf actions" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponseWithPlacement "book-test-001" testBook testPlacement)
                |> ProgramTest.ensureViewHas
                    [ Selector.class "book-detail__hero" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "book-detail__about" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "book-detail__reviews" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "book-detail__prices" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "book-detail__author-card" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "book-detail__writing" ]
                |> ProgramTest.expectViewHas
                    [ Selector.class "book-detail__shelf-actions" ]


failureRendersError : Test
failureRendersError =
    test "failure_renders_error: HTTP error response shows error message" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (Http.BadStatus_
                        { url = "/api/books/book-test-001"
                        , statusCode = 500
                        , statusText = "Internal Server Error"
                        , headers = Dict.empty
                        }
                        ""
                    )
                |> ProgramTest.expectViewHas
                    [ Selector.text "Could not load this book. Please try again." ]


forbiddenTriggersAgeGate : Test
forbiddenTriggersAgeGate =
    test "forbidden_triggers_age_gate: 403 response triggers age gate, dismiss hides it" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (Http.BadStatus_
                        { url = "/api/books/book-test-001"
                        , statusCode = 403
                        , statusText = "Forbidden"
                        , headers = Dict.empty
                        }
                        ""
                    )
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Age Verification Required" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "age-gate" ]
                |> ProgramTest.clickButton "Go Back"
                |> ProgramTest.expectViewHasNot
                    [ Selector.class "age-gate" ]


formatToggleUpdatesSelected : Test
formatToggleUpdatesSelected =
    test "format_toggle: clicking a format button adds selected class" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponseWithPlacement "book-test-001" testBook testPlacement)
                |> ProgramTest.clickButton "Physical"
                |> ProgramTest.expectViewHas
                    [ Selector.class "format-picker__btn--selected" ]


shelfMoverOpenSelectConfirmFlow : Test
shelfMoverOpenSelectConfirmFlow =
    test "shelf_mover_flow: open shelf mover, then cancel closes it" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponseWithPlacement "book-test-001" testBook testPlacement)
                |> ProgramTest.clickButton "Choose Bookshelf"
                |> ProgramTest.ensureViewHas
                    [ Selector.class "shelf-mover" ]
                |> ProgramTest.clickButton "Cancel"
                |> ProgramTest.expectViewHasNot
                    [ Selector.class "shelf-mover" ]


removeModalOpenConfirmFlow : Test
removeModalOpenConfirmFlow =
    test "remove_modal_flow: open remove modal shows confirmation, cancel closes it" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponseWithPlacement "book-test-001" testBook testPlacement)
                |> ProgramTest.clickButton "Remove from collection"
                |> ProgramTest.ensureViewHas
                    [ Selector.class "modal-overlay" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Are you sure you want to remove" ]
                |> ProgramTest.clickButton "Keep It"
                |> ProgramTest.expectViewHasNot
                    [ Selector.class "modal-overlay" ]


sectionContentDetails : Test
sectionContentDetails =
    test "section_content: reviews show source names, prices show empty message, author name visible" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponse "book-test-001" testBook)
                |> ProgramTest.ensureViewHas
                    [ Selector.text "GoodReads" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Storygraph" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Reddit" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "No price data yet" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Charles Duhigg" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Not yet rated" ]


placementLoadedShowsCurrentBookshelf : Test
placementLoadedShowsCurrentBookshelf =
    test "placement_loaded: when placement is returned, shelf actions show correct current bookshelf" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponseWithPlacement "book-test-001" testBook testPlacement)
                |> ProgramTest.clickButton "Choose Bookshelf"
                |> ProgramTest.expectViewHas
                    [ Selector.class "shelf-mover" ]


ariaRegionsPresent : Test
ariaRegionsPresent =
    test "aria_regions: sections have proper role=region attributes" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponse "book-test-001" testBook)
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "role" "region")
                    , Selector.id "section-about"
                    ]
                |> ProgramTest.expectViewHas
                    [ Selector.attribute (Html.Attributes.attribute "role" "region")
                    , Selector.id "section-reviews"
                    ]


ratingDisplayWithoutPlacement : Test
ratingDisplayWithoutPlacement =
    test "rating_display: without placement shows 'Not yet rated'" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponse "book-test-001" testBook)
                |> ProgramTest.expectViewHas
                    [ Selector.class "book-detail__rating--empty" ]



-- MOVE / REMOVE CONFIRM STATE-MACHINE COVERAGE (Issue #116 punch #15/#16)


moveEndpoint : String
moveEndpoint =
    "/api/placements/placement-test-001/move"


removeEndpoint : String
removeEndpoint =
    "/api/placements/placement-test-001"


{-| A successful move: `Api.moveResponseToResult` maps any 2xx to `Ok ()`.
-}
moveSuccessResponse : Http.Response String
moveSuccessResponse =
    Http.GoodStatus_
        { url = moveEndpoint
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        "{}"


{-| A successful remove: `expectWhatever` maps any 2xx to `Ok ()`.
-}
removeSuccessResponse : Http.Response String
removeSuccessResponse =
    Http.GoodStatus_
        { url = removeEndpoint
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        ""


{-| #15 move-happy: `OpenBookshelfMover → SelectBookshelf → ConfirmMove →
MoveCompleted (Ok _)` updates `currentBookshelf` (rendered in the shelf-actions
title), closes the mover, and renders the success message.
-}
moveConfirmHappyUpdatesBookshelf : Test
moveConfirmHappyUpdatesBookshelf =
    test "move_confirm_happy: SelectBookshelf then ConfirmMove then MoveCompleted Ok updates currentBookshelf, closes the mover, and shows success" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponseWithPlacement "book-test-001" testBook testPlacement)
                |> ProgramTest.clickButton "Choose Bookshelf"
                |> ProgramTest.update (BookDetail.SelectBookshelf "wishlist")
                |> ProgramTest.clickButton "Move"
                |> ProgramTest.simulateHttpResponse "PUT" moveEndpoint moveSuccessResponse
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Move to Shelf from Wish List" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Moved successfully." ]
                |> ProgramTest.expectViewHasNot
                    [ Selector.class "shelf-mover" ]


{-| #15 remove-happy: `OpenRemoveModal → ConfirmRemove → RemoveCompleted (Ok _)`
emits the OutMsg `NavigateTo previousRoute`. The page cannot observe its own
OutMsg, so this uses the `bookDetailProgramWithOut` harness (which records it)
with a concrete previous route to assert the navigation target.
-}
removeConfirmNavigatesToPreviousRoute : Test
removeConfirmNavigatesToPreviousRoute =
    test "remove_confirm_happy: ConfirmRemove then RemoveCompleted Ok emits OutMsg NavigateTo previousRoute" <|
        \() ->
            ProgramTest.start ()
                (bookDetailProgramWithOut "book-test-001" (Just "test-token") (Just Route.AntiLibrary))
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponseWithPlacement "book-test-001" testBook testPlacement)
                |> ProgramTest.clickButton "Remove from collection"
                |> ProgramTest.within (Query.find [ Selector.class "modal-overlay" ])
                    (ProgramTest.clickButton "Remove")
                |> ProgramTest.simulateHttpResponse "DELETE" removeEndpoint removeSuccessResponse
                |> ProgramTest.expectModel
                    (\model -> Expect.equal (BookDetail.NavigateTo Route.AntiLibrary) model.lastOut)


{-| #16 remove-sad: `RemoveCompleted (Err _)` renders the remove failure copy.
-}
removeCompletedErrorShowsMessage : Test
removeCompletedErrorShowsMessage =
    test "remove_completed_error: a failed DELETE renders the remove failure message" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponseWithPlacement "book-test-001" testBook testPlacement)
                |> ProgramTest.clickButton "Remove from collection"
                |> ProgramTest.within (Query.find [ Selector.class "modal-overlay" ])
                    (ProgramTest.clickButton "Remove")
                |> ProgramTest.simulateHttpResponse "DELETE"
                    removeEndpoint
                    (Http.BadStatus_
                        { url = removeEndpoint
                        , statusCode = 500
                        , statusText = "Internal Server Error"
                        , headers = Dict.empty
                        }
                        ""
                    )
                |> ProgramTest.expectViewHas
                    [ Selector.text "Failed to remove book. Please try again." ]


{-| #16 no-op guard: `ConfirmMove` with `placement == Nothing` fires no request
(the simulated-effect layer's `(Just placement, Just token)` guard fails) and
leaves `moveState` untouched.
-}
confirmMoveNoPlacementIsNoOp : Test
confirmMoveNoPlacementIsNoOp =
    test "confirm_move_no_placement: ConfirmMove with no placement fires no request and leaves moveState untouched" <|
        \() ->
            startBookDetail
                |> ProgramTest.update
                    (BookDetail.BookLoaded
                        (Ok { book = testBook, placement = Nothing, bookshelfVisibility = Nothing })
                    )
                |> ProgramTest.update BookDetail.ConfirmMove
                |> ProgramTest.ensureHttpRequests "PUT" moveEndpoint (List.length >> Expect.equal 0)
                |> ProgramTest.expectModel (\model -> Expect.equal NotAsked model.moveState)


{-| #16 no-op guard: `ConfirmMove` with a placement but `maybeToken == Nothing`
fires no request and leaves `moveState` untouched. The placement is injected via
`BookLoaded` because the no-token init makes no GET.
-}
confirmMoveNoTokenIsNoOp : Test
confirmMoveNoTokenIsNoOp =
    test "confirm_move_no_token: ConfirmMove with a placement but no token fires no request and leaves moveState untouched" <|
        \() ->
            ProgramTest.start () (bookDetailProgram "book-test-001" Nothing)
                |> ProgramTest.update
                    (BookDetail.BookLoaded
                        (Ok { book = testBook, placement = Just testPlacement, bookshelfVisibility = Nothing })
                    )
                |> ProgramTest.update BookDetail.ConfirmMove
                |> ProgramTest.ensureHttpRequests "PUT" moveEndpoint (List.length >> Expect.equal 0)
                |> ProgramTest.expectModel (\model -> Expect.equal NotAsked model.moveState)


{-| #16 no-op guard: `ConfirmRemove` with `placement == Nothing` fires no request
and leaves `removeState` untouched.
-}
confirmRemoveNoPlacementIsNoOp : Test
confirmRemoveNoPlacementIsNoOp =
    test "confirm_remove_no_placement: ConfirmRemove with no placement fires no request and leaves removeState untouched" <|
        \() ->
            startBookDetail
                |> ProgramTest.update
                    (BookDetail.BookLoaded
                        (Ok { book = testBook, placement = Nothing, bookshelfVisibility = Nothing })
                    )
                |> ProgramTest.update BookDetail.ConfirmRemove
                |> ProgramTest.ensureHttpRequests "DELETE" removeEndpoint (List.length >> Expect.equal 0)
                |> ProgramTest.expectModel (\model -> Expect.equal NotAsked model.removeState)


{-| #16 no-op guard: `ConfirmRemove` with a placement but `maybeToken == Nothing`
fires no request and leaves `removeState` untouched.
-}
confirmRemoveNoTokenIsNoOp : Test
confirmRemoveNoTokenIsNoOp =
    test "confirm_remove_no_token: ConfirmRemove with a placement but no token fires no request and leaves removeState untouched" <|
        \() ->
            ProgramTest.start () (bookDetailProgram "book-test-001" Nothing)
                |> ProgramTest.update
                    (BookDetail.BookLoaded
                        (Ok { book = testBook, placement = Just testPlacement, bookshelfVisibility = Nothing })
                    )
                |> ProgramTest.update BookDetail.ConfirmRemove
                |> ProgramTest.ensureHttpRequests "DELETE" removeEndpoint (List.length >> Expect.equal 0)
                |> ProgramTest.expectModel (\model -> Expect.equal NotAsked model.removeState)
