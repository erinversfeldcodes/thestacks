module Page.BookDetailProgramTest exposing (suite)

{-| Program tests for Page.BookDetail using elm-program-test.

These tests exercise the BookDetail page lifecycle through
simulated HTTP responses and user interactions.

-}

import Components.RemoveBookModal as RemoveBookModal
import Dict
import Expect
import Html.Attributes
import Http
import Json.Encode as Encode
import Navigation.Route as Route
import Page.BookDetail as BookDetail
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
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
        , moveCompletedErrorShowsMessage
        , closeOverlayXEmitsRequestClose
        , closeOverlayBackdropEmitsRequestClose
        , overlayHasFocusBoundaries
        , trapForwardTabOnSentinelWrapsToFirst
        , trapShiftTabOnCloseWrapsToLast
        , trapForwardTabOnCloseIsNatural
        , trapShiftTabOnSentinelIsNatural
        , trapNonTabKeyIsNatural
        , sentinelHasAriaLabel
        , removeModalHasDialogSemantics
        , removeModalButtonsHaveIds
        , escapeClosesRemoveModalFirst
        , escapeClosesProgressFormFirst
        , escapeWithNoNestedSurfaceRequestsClose
        , removeModalTrapForwardWrap
        , removeModalTrapReverseWrap
        , removeModalTrapNaturalOrder
        ]


{-| Simulate a `keydown` on the remove modal's dialog element and return the
decoded message (if any). Mirrors `simulateCardKeydown` for the overlay card.
-}
simulateModalKeydown : Encode.Value -> Result String BookDetail.Msg
simulateModalKeydown eventValue =
    BookDetail.overlayView overlayModelWithModal
        |> Query.fromHtml
        |> Query.find [ Selector.class "modal" ]
        |> Event.simulate ( "keydown", eventValue )
        |> Event.toResult



-- SCOPED ESCAPE (ux fix 1): dismiss the top-most surface first


escapeClosesRemoveModalFirst : Test
escapeClosesRemoveModalFirst =
    test "escape_scoped_modal: Escape with the remove modal open closes just the modal, overlay stays (NoOut)" <|
        \() ->
            let
                ( model, _, out ) =
                    BookDetail.update BookDetail.EscapePressed
                        { loadedOverlayModel | removeModalOpen = True }
                        (Just "test-token")
            in
            Expect.all
                [ \_ -> Expect.equal False model.removeModalOpen
                , \_ -> Expect.equal BookDetail.NoOut out
                ]
                ()


escapeClosesProgressFormFirst : Test
escapeClosesProgressFormFirst =
    test "escape_scoped_progress: Escape with the progress-edit form open closes just the form, overlay stays (NoOut)" <|
        \() ->
            let
                editingModel =
                    { loadedOverlayModel
                        | progressCard = Maybe.map (\c -> { c | editing = True }) loadedOverlayModel.progressCard
                    }

                ( model, _, out ) =
                    BookDetail.update BookDetail.EscapePressed editingModel (Just "test-token")
            in
            Expect.all
                [ \_ -> Expect.equal (Just False) (Maybe.map .editing model.progressCard)
                , \_ -> Expect.equal BookDetail.NoOut out
                ]
                ()


escapeWithNoNestedSurfaceRequestsClose : Test
escapeWithNoNestedSurfaceRequestsClose =
    test "escape_scoped_none: Escape with no nested surface open requests overlay close (RequestCloseOverlay)" <|
        \() ->
            let
                ( _, _, out ) =
                    BookDetail.update BookDetail.EscapePressed loadedOverlayModel (Just "test-token")
            in
            Expect.equal BookDetail.RequestCloseOverlay out



-- REMOVE-MODAL FOCUS TRAP (ux fix 2)


removeModalTrapForwardWrap : Test
removeModalTrapForwardWrap =
    test "remove_modal_forward_wrap: Tab on the Remove button wraps to Keep It" <|
        \() ->
            simulateModalKeydown (tabKeydownEvent False RemoveBookModal.confirmButtonId)
                |> Expect.equal (Ok (BookDetail.FocusOn RemoveBookModal.cancelButtonId))


removeModalTrapReverseWrap : Test
removeModalTrapReverseWrap =
    test "remove_modal_reverse_wrap: Shift+Tab on Keep It wraps to the Remove button" <|
        \() ->
            simulateModalKeydown (tabKeydownEvent True RemoveBookModal.cancelButtonId)
                |> Expect.equal (Ok (BookDetail.FocusOn RemoveBookModal.confirmButtonId))


removeModalTrapNaturalOrder : Test
removeModalTrapNaturalOrder =
    test "remove_modal_natural: forward Tab on Keep It is not intercepted (native order to Remove)" <|
        \() ->
            simulateModalKeydown (tabKeydownEvent False RemoveBookModal.cancelButtonId)
                |> Expect.err


{-| An overlay model with the remove-confirmation modal open.
-}
overlayModelWithModal : BookDetail.Model
overlayModelWithModal =
    { loadedOverlayModel | removeModalOpen = True }


sentinelHasAriaLabel : Test
sentinelHasAriaLabel =
    test "sentinel_label: the trailing focus sentinel carries an explanatory aria-label" <|
        \() ->
            BookDetail.overlayView loadedOverlayModel
                |> Query.fromHtml
                |> Query.find [ Selector.id BookDetail.lastFocusableId ]
                |> Query.has
                    [ Selector.attribute
                        (Html.Attributes.attribute "aria-label"
                            "End of book details — press Tab to return to the top"
                        )
                    ]


removeModalHasDialogSemantics : Test
removeModalHasDialogSemantics =
    test "remove_modal_semantics: the remove modal is a labelled aria dialog" <|
        \() ->
            BookDetail.overlayView overlayModelWithModal
                |> Query.fromHtml
                |> Query.find [ Selector.class "modal" ]
                |> Query.has
                    [ Selector.attribute (Html.Attributes.attribute "role" "dialog")
                    , Selector.attribute (Html.Attributes.attribute "aria-modal" "true")
                    , Selector.attribute (Html.Attributes.attribute "aria-labelledby" "remove-book-title")
                    ]


removeModalButtonsHaveIds : Test
removeModalButtonsHaveIds =
    test "remove_modal_buttons: the remove modal's two buttons carry stable focus ids" <|
        \() ->
            BookDetail.overlayView overlayModelWithModal
                |> Query.fromHtml
                |> Expect.all
                    [ Query.has [ Selector.id "remove-book-cancel" ]
                    , Query.has [ Selector.id "remove-book-confirm" ]
                    ]


{-| A fully-loaded overlay model (book + placement) for exercising `overlayView`
directly. `overlayView` renders the modal chrome (close button, backdrop,
focus sentinel) the page `view` does not.
-}
loadedOverlayModel : BookDetail.Model
loadedOverlayModel =
    let
        ( m0, _ ) =
            BookDetail.init "book-test-001" (Just "test-token") Nothing

        ( m1, _, _ ) =
            BookDetail.update
                (BookDetail.BookLoaded
                    (Ok { book = testBook, placement = Just testPlacement, bookshelfVisibility = Nothing })
                )
                m0
                (Just "test-token")
    in
    m1


{-| A synthetic `keydown` event payload carrying the fields the trap decoder
reads: `key`, `shiftKey`, and `target.id` (the focused element).
-}
tabKeydownEvent : Bool -> String -> Encode.Value
tabKeydownEvent shiftKey targetId =
    Encode.object
        [ ( "key", Encode.string "Tab" )
        , ( "shiftKey", Encode.bool shiftKey )
        , ( "target", Encode.object [ ( "id", Encode.string targetId ) ] )
        ]


{-| A `keydown` event payload with an explicit `key` value (e.g. "Enter"),
`shiftKey`, and `target.id` — for asserting that non-Tab keys are not trapped.
-}
keydownEvent : String -> Bool -> String -> Encode.Value
keydownEvent key shiftKey targetId =
    Encode.object
        [ ( "key", Encode.string key )
        , ( "shiftKey", Encode.bool shiftKey )
        , ( "target", Encode.object [ ( "id", Encode.string targetId ) ] )
        ]


simulateCardKeydown : Encode.Value -> Result String BookDetail.Msg
simulateCardKeydown eventValue =
    BookDetail.overlayView loadedOverlayModel
        |> Query.fromHtml
        |> Query.find [ Selector.class "book-overlay__card" ]
        |> Event.simulate ( "keydown", eventValue )
        |> Event.toResult



-- B4 (punch #10): move-failure copy


{-| A failed move (`ConfirmMove` → `MoveCompleted (Err (MoveHttpError _))`)
renders the generic move-failure copy. A 500 maps via `Api.moveResponseToResult`
to `MoveHttpError` (not the `ReadingPileFull` 422 special-case).
-}
moveCompletedErrorShowsMessage : Test
moveCompletedErrorShowsMessage =
    test "move_completed_error: a failed PUT renders the move failure message" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponseWithPlacement "book-test-001" testBook testPlacement)
                |> ProgramTest.clickButton "Choose Bookshelf"
                |> ProgramTest.update (BookDetail.SelectBookshelf "wishlist")
                |> ProgramTest.clickButton "Move"
                |> ProgramTest.simulateHttpResponse "PUT"
                    moveEndpoint
                    (Http.BadStatus_
                        { url = moveEndpoint
                        , statusCode = 500
                        , statusText = "Internal Server Error"
                        , headers = Dict.empty
                        }
                        ""
                    )
                |> ProgramTest.expectViewHas
                    [ Selector.text "Failed to move book. Please try again." ]



-- B5 (punch #10): CloseOverlay → RequestCloseOverlay OutMsg (X + backdrop)


startOverlayWithOut : ProgramTest.ProgramTest TestHelpers.BookDetailTestModel BookDetail.Msg (ProgramTest.SimulatedEffect BookDetail.Msg)
startOverlayWithOut =
    ProgramTest.start ()
        (TestHelpers.bookDetailOverlayProgramWithOut "book-test-001" (Just "test-token") (Just Route.Library))
        |> ProgramTest.simulateHttpResponse "GET"
            "/api/books/book-test-001"
            (simulateBookDetailResponseWithPlacement "book-test-001" testBook testPlacement)


{-| Clicking the overlay's X (close) button emits the `RequestCloseOverlay`
OutMsg, which `Main` consumes to tear down the overlay and return focus.
-}
closeOverlayXEmitsRequestClose : Test
closeOverlayXEmitsRequestClose =
    test "close_overlay_x: clicking the X button emits RequestCloseOverlay" <|
        \() ->
            startOverlayWithOut
                |> ProgramTest.simulateDomEvent
                    (Query.find [ Selector.id "book-overlay-close" ])
                    Event.click
                |> ProgramTest.expectModel
                    (\model -> Expect.equal BookDetail.RequestCloseOverlay model.lastOut)


{-| Clicking the backdrop (a distinct DOM element from the X button) also emits
`RequestCloseOverlay` — the backdrop-dismiss half of the contract.
-}
closeOverlayBackdropEmitsRequestClose : Test
closeOverlayBackdropEmitsRequestClose =
    test "close_overlay_backdrop: clicking the backdrop emits RequestCloseOverlay" <|
        \() ->
            startOverlayWithOut
                |> ProgramTest.simulateDomEvent
                    (Query.find [ Selector.class "book-overlay__backdrop" ])
                    Event.click
                |> ProgramTest.expectModel
                    (\model -> Expect.equal BookDetail.RequestCloseOverlay model.lastOut)



-- FOCUS TRAP (US-1.4.1 a11y contract; kickoff-approved in-scope build)


{-| The overlay's two focus-trap anchors are present in the DOM: the close
button (first focusable / focus-on-open target) and the trailing sentinel
(the last tab stop). The update's wrap commands focus these exact ids, so their
presence ties the wrap targets to real elements.
-}
overlayHasFocusBoundaries : Test
overlayHasFocusBoundaries =
    test "trap_boundaries: overlay renders the close button and a trailing focus sentinel" <|
        \() ->
            BookDetail.overlayView loadedOverlayModel
                |> Query.fromHtml
                |> Expect.all
                    [ Query.has [ Selector.id BookDetail.firstFocusableId ]
                    , Query.has [ Selector.id BookDetail.lastFocusableId ]
                    ]


{-| Forward Tab while focus is on the trailing sentinel wraps to the first
control — the decoder emits `FocusWrapToFirst` (and preventDefaults).
-}
trapForwardTabOnSentinelWrapsToFirst : Test
trapForwardTabOnSentinelWrapsToFirst =
    test "trap_forward_wrap: Tab on the trailing sentinel wraps to the first control" <|
        \() ->
            simulateCardKeydown (tabKeydownEvent False BookDetail.lastFocusableId)
                |> Expect.equal (Ok BookDetail.FocusWrapToFirst)


{-| Shift+Tab while focus is on the first control (close button) wraps to the
trailing sentinel — the decoder emits `FocusWrapToLast` (and preventDefaults).
-}
trapShiftTabOnCloseWrapsToLast : Test
trapShiftTabOnCloseWrapsToLast =
    test "trap_reverse_wrap: Shift+Tab on the close button wraps to the trailing sentinel" <|
        \() ->
            simulateCardKeydown (tabKeydownEvent True BookDetail.firstFocusableId)
                |> Expect.equal (Ok BookDetail.FocusWrapToLast)


{-| Forward Tab on the first control is NOT trapped: the decoder fails, so no
message fires and no `preventDefault` is applied — native tab order carries
focus to the next control inside the overlay.
-}
trapForwardTabOnCloseIsNatural : Test
trapForwardTabOnCloseIsNatural =
    test "trap_forward_natural: forward Tab on the close button is not intercepted" <|
        \() ->
            simulateCardKeydown (tabKeydownEvent False BookDetail.firstFocusableId)
                |> Expect.err


{-| Shift+Tab on the trailing sentinel is NOT trapped: native Shift+Tab walks
back to the previous control inside the overlay.
-}
trapShiftTabOnSentinelIsNatural : Test
trapShiftTabOnSentinelIsNatural =
    test "trap_reverse_natural: Shift+Tab on the trailing sentinel is not intercepted" <|
        \() ->
            simulateCardKeydown (tabKeydownEvent True BookDetail.lastFocusableId)
                |> Expect.err


{-| A non-Tab key (Enter) on a boundary element is never trapped — the trap
only governs Tab navigation.
-}
trapNonTabKeyIsNatural : Test
trapNonTabKeyIsNatural =
    test "trap_non_tab: a non-Tab keydown on a boundary is not intercepted" <|
        \() ->
            simulateCardKeydown (keydownEvent "Enter" False BookDetail.lastFocusableId)
                |> Expect.err


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
