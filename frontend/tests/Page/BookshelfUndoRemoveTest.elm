module Page.BookshelfUndoRemoveTest exposing (suite)

{-| Program tests for the "Removed — Undo" toast. The undo restores the
SAME placement row (`POST /api/placements/:id/restore`), so ratings,
notes and `placed_at` survive. Covers the toast render, the restore
request, expiry, and the read-only inertness of a synthetic undo.
-}

import Expect
import Html.Attributes
import Http
import Main
import Page.Bookshelf as Bookshelf
import Page.Home as Home
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers exposing (bookshelfUndoProgram, simulateBookshelfResponse, testPlacement)


removal : Bookshelf.Removal
removal =
    { placementId = "placement-42", bookTitle = "The Dispossessed" }


restoreEndpoint : String
restoreEndpoint =
    "/api/placements/placement-42/restore"


libraryEndpoint : String
libraryEndpoint =
    "/api/bookshelves/library"


{-| The owner's Library, freshly arrived at off a removal.
-}
afterRemoval : ProgramTest.ProgramTest Bookshelf.Model Bookshelf.Msg (ProgramTest.SimulatedEffect Bookshelf.Msg)
afterRemoval =
    ProgramTest.start () (bookshelfUndoProgram Bookshelf.libraryConfig (Just "owner-token") removal)
        |> ProgramTest.simulateHttpResponse "GET"
            libraryEndpoint
            (simulateBookshelfResponse [ testPlacement ])


{-| The same arrival, on ANOTHER reader's shelf. Impossible to reach in
production — `Main.applyPendingUndo` only ever hands the removal to the shelf the
remover was standing on — but that is the point: the guarantee must hold because
of `mutationToken`, not because of how the page happens to be reached.
-}
readOnlyAfterRemoval : ProgramTest.ProgramTest Bookshelf.Model Bookshelf.Msg (ProgramTest.SimulatedEffect Bookshelf.Msg)
readOnlyAfterRemoval =
    ProgramTest.start ()
        (bookshelfUndoProgram (Bookshelf.profileConfig "alice" "library") (Just "viewer-token") removal)


suite : Test
suite =
    describe "Page.Bookshelf — undo remove"
        [ toastOffersUndoNamingTheBook
        , undoPostsToRestoreTheSameRow
        , ownerUndoIsObservable
        , readOnlyUndoIsInert
        , readOnlySyntheticUndoMsg
        , readOnlySyntheticUndoLeavesStateAlone
        , readOnlyShowsNoToast
        , toastDisappearsWhenExpired
        , undoAfterExpiryIssuesNothing
        , successHidesToastAndRefetches
        , conflictSaysTheBookIsAlreadyBack
        , failureToastSurvivesItsTimer
        , secondUndoWhileRestoringIsInert
        , plainVisitOffersNoUndo
        , theWindowIsAFewSeconds
        , mainHandsTheRemovalToTheShelf
        , mainKeepsAPlainVisitPlain
        , mainDropsTheOfferOnANonBookshelfPage
        ]


{-| The owner ruling was "a toast for a few seconds", and "a few seconds" is a
product decision, not an implementation detail — the modal now promises it in so
many words ("You'll have a few seconds to undo it"). A range rather than an
equality, because the exact number is free to be tuned and 8000 is not worth a
test failure; what is worth one is someone typing 800 or 80000 and making the
copy a lie in one direction or the toast furniture in the other.
-}
theWindowIsAFewSeconds : Test
theWindowIsAFewSeconds =
    test "undo_window_is_a_few_seconds: the offer lasts long enough to read and not long enough to forget" <|
        \() ->
            Bookshelf.undoToastMillis
                |> Expect.all
                    [ Expect.atLeast 4000
                    , Expect.atMost 15000
                    ]


{-| A bookshelf page built during the `UrlChanged` a removal provokes comes out
holding the offer.
-}
mainHandsTheRemovalToTheShelf : Test
mainHandsTheRemovalToTheShelf =
    test "main_hands_the_removal_to_the_shelf: applyPendingUndo seeds the toast on PageBookshelf" <|
        \() ->
            let
                ( model, _ ) =
                    Bookshelf.init Bookshelf.libraryConfig (Just "owner-token") "u1"

                ( page, _ ) =
                    Main.applyPendingUndo (Just removal) ( Main.PageBookshelf model, Cmd.none )
            in
            case page of
                Main.PageBookshelf seeded ->
                    Expect.equal (Bookshelf.ToastOffered removal) seeded.undoToast

                _ ->
                    Expect.fail "applyPendingUndo changed which page was built"


mainKeepsAPlainVisitPlain : Test
mainKeepsAPlainVisitPlain =
    test "main_keeps_a_plain_visit_plain: no pending removal leaves the shelf without a toast" <|
        \() ->
            let
                ( model, _ ) =
                    Bookshelf.init Bookshelf.libraryConfig (Just "owner-token") "u1"

                ( page, _ ) =
                    Main.applyPendingUndo Nothing ( Main.PageBookshelf model, Cmd.none )
            in
            case page of
                Main.PageBookshelf untouched ->
                    Expect.equal Bookshelf.ToastHidden untouched.undoToast

                _ ->
                    Expect.fail "applyPendingUndo changed which page was built"


mainDropsTheOfferOnANonBookshelfPage : Test
mainDropsTheOfferOnANonBookshelfPage =
    test "main_drops_the_offer_off_a_non_bookshelf_page: the documented Reading-Pile gap is a no-op, not a crash" <|
        \() ->
            Main.applyPendingUndo (Just removal) ( Main.PageHome Home.Landing, Cmd.none )
                |> Tuple.first
                |> Expect.equal (Main.PageHome Home.Landing)


toastOffersUndoNamingTheBook : Test
toastOffersUndoNamingTheBook =
    test "toast_names_the_removed_book: the offer says what was removed, not just that something was" <|
        \() ->
            afterRemoval
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "undo-toast") ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Removed “The Dispossessed”." ]


undoPostsToRestoreTheSameRow : Test
undoPostsToRestoreTheSameRow =
    test "undo_restores_the_same_placement_row: the request names the removed placement's id" <|
        \() ->
            afterRemoval
                |> ProgramTest.clickButton "Undo"
                |> ProgramTest.ensureHttpRequestWasMade "POST" restoreEndpoint
                |> ProgramTest.expectHttpRequests "POST"
                    "/api/bookshelves/library/placements"
                    (\requests -> Expect.equal (List.length requests) 0)


{-| ⚠️ **POSITIVE CONTROL for the two SECURITY tests below.**

Same page module, same harness, same drive, same seeded toast — only the config
differs. If this goes red, the assertions below have stopped distinguishing
anything: they would be counting POSTs in a world where no `Bookshelf.Msg` can
produce one, which is exactly how `BookshelfReadOnlyTest`'s equivalent assertion
was silently disarmed before.

-}
ownerUndoIsObservable : Test
ownerUndoIsObservable =
    test "owner_undo_is_observable: the SAME harness in owner mode DOES issue the restore POST" <|
        \() ->
            afterRemoval
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "undo-remove") ]
                |> ProgramTest.update Bookshelf.UndoRemove
                |> ProgramTest.expectHttpRequests "POST"
                    restoreEndpoint
                    (\requests -> Expect.equal (List.length requests) 1)


{-| The guard asserted where it is enforced, with no harness in the path.

`Bookshelf.update` is driven directly and the `Cmd` it returns is inspected —
the only thing that decides whether a request leaves the browser. The model is
read-only, holds a valid viewer token, has loaded shelves, and is holding an
`Offered` toast: every precondition the mutating branch needs except the one
`mutationToken` withholds.

Two assertions because they fail independently: the command is the request, and
the toast state is the page telling the reader an undo is under way.

-}
readOnlyUndoIsInert : Test
readOnlyUndoIsInert =
    test "read_only_undo_is_inert_SECURITY: UndoRemove on a read-only shelf produces no command" <|
        \() ->
            let
                ( initial, _ ) =
                    Bookshelf.init
                        (Bookshelf.profileConfig "alice" "library")
                        (Just "viewer-token")
                        "viewer-user-id"

                ( seeded, _ ) =
                    Bookshelf.withPendingUndo (Just removal) ( initial, Cmd.none )

                ( loaded, _, _ ) =
                    Bookshelf.update
                        (Bookshelf.ShelvesLoaded
                            (Bookshelf.requestKey seeded.config)
                            (Ok { shelves = [], visibility = "owner" })
                        )
                        seeded

                ( after, cmd, _ ) =
                    Bookshelf.update Bookshelf.UndoRemove loaded
            in
            Expect.all
                [ \_ -> Expect.equal (Bookshelf.ToastOffered removal) loaded.undoToast
                , \_ -> Expect.equal Cmd.none cmd
                , \_ -> Expect.equal (Bookshelf.ToastOffered removal) after.undoToast
                ]
                ()


{-| The same guarantee through the whole program: a synthetic `UndoRemove`
delivered to a running read-only browse leaves the request log
untouched. Paired with `ownerUndoIsObservable` (the positive control).
The model assertion matters: `libraryEffects` reads `mutationToken`
itself, so the enforcement point under test is the real one.
-}
readOnlySyntheticUndoMsg : Test
readOnlySyntheticUndoMsg =
    test "read_only_synthetic_undo_msg_SECURITY: an UndoRemove bypassing the view neither requests nor changes state" <|
        \() ->
            readOnlyAfterRemoval
                |> ProgramTest.update Bookshelf.UndoRemove
                |> ProgramTest.expectHttpRequests "POST"
                    restoreEndpoint
                    (\requests -> Expect.equal (List.length requests) 0)


readOnlySyntheticUndoLeavesStateAlone : Test
readOnlySyntheticUndoLeavesStateAlone =
    test "read_only_synthetic_undo_state_SECURITY: the same message does not move the page into ToastRestoring" <|
        \() ->
            readOnlyAfterRemoval
                |> ProgramTest.update Bookshelf.UndoRemove
                |> ProgramTest.expectModel
                    (\model ->
                        Expect.equal (Bookshelf.ToastOffered removal) model.undoToast
                    )


readOnlyShowsNoToast : Test
readOnlyShowsNoToast =
    test "read_only_no_undo_control_SECURITY: the toast is absent, not merely disabled" <|
        \() ->
            readOnlyAfterRemoval
                |> ProgramTest.expectViewHasNot
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "undo-toast") ]


toastDisappearsWhenExpired : Test
toastDisappearsWhenExpired =
    test "toast_expires: the offer is withdrawn when its timer fires" <|
        \() ->
            afterRemoval
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "undo-toast") ]
                |> ProgramTest.update Bookshelf.ToastExpired
                |> ProgramTest.expectViewHasNot
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "undo-toast") ]


undoAfterExpiryIssuesNothing : Test
undoAfterExpiryIssuesNothing =
    test "undo_after_expiry_issues_nothing: a late click on a withdrawn offer is inert" <|
        \() ->
            afterRemoval
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "undo-remove") ]
                |> ProgramTest.update Bookshelf.ToastExpired
                |> ProgramTest.update Bookshelf.UndoRemove
                |> ProgramTest.expectHttpRequests "POST"
                    restoreEndpoint
                    (\requests -> Expect.equal (List.length requests) 0)


successHidesToastAndRefetches : Test
successHidesToastAndRefetches =
    test "undo_success_refetches_the_shelf: the toast goes and the bookshelf is re-fetched" <|
        \() ->
            afterRemoval
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "undo-toast") ]
                |> ProgramTest.clickButton "Undo"
                |> ProgramTest.update (Bookshelf.UndoCompleted (Ok ()))
                |> ProgramTest.ensureViewHasNot
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "undo-toast") ]
                |> ProgramTest.ensureHttpRequestWasMade "GET" libraryEndpoint
                |> ProgramTest.expectHttpRequests "GET"
                    libraryEndpoint
                    (\requests -> Expect.equal (List.length requests) 1)


conflictSaysTheBookIsAlreadyBack : Test
conflictSaysTheBookIsAlreadyBack =
    test "undo_conflict_copy: a 409 says the book is already back, not that something went wrong" <|
        \() ->
            afterRemoval
                |> ProgramTest.clickButton "Undo"
                |> ProgramTest.update (Bookshelf.UndoCompleted (Err (Http.BadStatus 409)))
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "undo-toast-error") ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "That book is already back on your Library." ]


failureToastSurvivesItsTimer : Test
failureToastSurvivesItsTimer =
    test "undo_failure_is_not_swept_away: the expiry timer does not clear a failure the reader must read" <|
        \() ->
            afterRemoval
                |> ProgramTest.clickButton "Undo"
                |> ProgramTest.update (Bookshelf.UndoCompleted (Err Http.NetworkError))
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "undo-toast-error") ]
                |> ProgramTest.update Bookshelf.ToastExpired
                |> ProgramTest.expectViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "undo-toast-error") ]


secondUndoWhileRestoringIsInert : Test
secondUndoWhileRestoringIsInert =
    test "double_undo_sends_one_request: a second click while the restore is in flight is ignored" <|
        \() ->
            afterRemoval
                |> ProgramTest.update Bookshelf.UndoRemove
                |> ProgramTest.update Bookshelf.UndoRemove
                |> ProgramTest.expectHttpRequests "POST"
                    restoreEndpoint
                    (\requests -> Expect.equal (List.length requests) 1)


plainVisitOffersNoUndo : Test
plainVisitOffersNoUndo =
    test "plain_visit_offers_no_undo: a bookshelf reached without a removal shows no toast" <|
        \() ->
            let
                ( model, _ ) =
                    Bookshelf.init Bookshelf.libraryConfig (Just "owner-token") "test-user-id"

                ( untouched, cmd ) =
                    Bookshelf.withPendingUndo Nothing ( model, Cmd.none )
            in
            Expect.all
                [ \_ -> Expect.equal Bookshelf.ToastHidden untouched.undoToast
                , \_ -> Expect.equal Cmd.none cmd
                ]
                ()
