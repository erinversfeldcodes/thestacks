module PlacementCardTest exposing (suite)

{-| Unit tests for Components.PlacementCard view rendering.

Tests verify badge label/class for each ReadingStatus value,
progress text for Reading placements, finished-at text for
Completed placements, and SaveClicked OutMsg payload.

-}

import Components.PlacementCard as Card
import Expect
import Html.Attributes
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers exposing (testPlacement)
import Types.Placement exposing (ReadingStatus(..))


readingModel : Card.Model
readingModel =
    Card.init
        { testPlacement
            | readingStatus = Just Reading
            , currentPage = Nothing
        }


readingWithPageModel : Card.Model
readingWithPageModel =
    Card.init
        { testPlacement
            | readingStatus = Just Reading
            , currentPage = Just 80
        }


noStatusModel : Card.Model
noStatusModel =
    Card.init
        { testPlacement
            | readingStatus = Nothing
        }


completedModel : Card.Model
completedModel =
    Card.init
        { testPlacement
            | readingStatus = Just Completed
            , finishedAt = Just "2026-03-15T10:00:00Z"
        }


abandonedModel : Card.Model
abandonedModel =
    Card.init
        { testPlacement
            | readingStatus = Just Abandoned
        }


suite : Test
suite =
    describe "Components.PlacementCard"
        [ describe "reading status badge label and class"
            [ test "Reading status shows badge label 'Reading'" <|
                \_ ->
                    Card.view readingModel
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.attribute
                                (Html.Attributes.attribute "data-testid" "reading-status-badge")
                            ]
                        |> Query.has [ Selector.text "Reading" ]
            , test "⛔ with NO recorded status, Save is DISABLED — the destructive half" <|
                -- ⛔ The assertion that matters most, and the one that was
                -- missing. A badge rendering the wrong label is wrong on screen;
                -- a card that SAVES the wrong label is wrong in the database.
                -- `init` used to seed `draftStatus` with `ToRead`, so opening
                -- the card and pressing Save without touching the dropdown
                -- wrote `to_read` over whatever the server held — including
                -- over a status this build could not parse.
                --
                -- ⚠️ Probed: restoring that default leaves 2147 of 2148 tests
                -- green, so nothing else in the suite holds this.
                \_ ->
                    Card.update Card.BadgeClicked noStatusModel
                        |> Tuple.first
                        |> Card.view
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.attribute
                                (Html.Attributes.attribute "data-testid" "save-progress-btn")
                            ]
                        |> Query.has [ Selector.disabled True ]
            , test "once a status is chosen, Save becomes available" <|
                -- The other half: the guard must not make the form unusable.
                \_ ->
                    noStatusModel
                        |> Card.update Card.BadgeClicked
                        |> Tuple.first
                        |> Card.update (Card.StatusChanged "reading")
                        |> Tuple.first
                        |> Card.view
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.attribute
                                (Html.Attributes.attribute "data-testid" "save-progress-btn")
                            ]
                        |> Query.has [ Selector.disabled False ]
            , test "⛔ a status string this build cannot parse leaves Save DISABLED" <|
                -- ⛔ The original defect's last door. `StatusChanged` used to go
                -- through a total `String -> ReadingStatus` ending in
                -- `_ -> ToRead`, so ANY unrecognised value — the placeholder
                -- option's empty string, or a fifth status a newer server sends
                -- during a deploy-skew window — became `Just ToRead`. That
                -- re-enables Save and writes `to_read` over whatever the server
                -- held, which is exactly the write this whole change removes.
                --
                -- ⚠️ What stood in the way was `disabled` on the placeholder
                -- `<option>`, i.e. the browser honouring an attribute, which is
                -- a thin thing to hang a destructive write on. `draftStatus` is
                -- now `parseReadingStatus s`, so an unrecognised value stays
                -- `Nothing` and the guard holds on its own.
                -- ⚠️ Each spelling asserted SEPARATELY. The first version
                -- chained both `StatusChanged` calls into one pipeline, so the
                -- second overwrote the first and only `"serialised_by_a_newer_
                -- server"` was ever asserted — the empty-string case, which is
                -- the one the placeholder `<option>` actually emits, was
                -- shadowed and never tested.
                \_ ->
                    let
                        saveDisabledAfter : String -> Expect.Expectation
                        saveDisabledAfter spelling =
                            noStatusModel
                                |> Card.update Card.BadgeClicked
                                |> Tuple.first
                                |> Card.update (Card.StatusChanged spelling)
                                |> Tuple.first
                                |> Card.view
                                |> Query.fromHtml
                                |> Query.find
                                    [ Selector.attribute
                                        (Html.Attributes.attribute "data-testid" "save-progress-btn")
                                    ]
                                |> Query.has [ Selector.disabled True ]
                    in
                    Expect.all
                        [ \_ -> saveDisabledAfter ""
                        , \_ -> saveDisabledAfter "serialised_by_a_newer_server"
                        , \_ -> saveDisabledAfter "finished"
                        ]
                        ()
            , test "Reading status badge has class 'placement-card__badge--reading'" <|
                \_ ->
                    Card.view readingModel
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.attribute
                                (Html.Attributes.attribute "data-testid" "reading-status-badge")
                            ]
                        |> Query.has [ Selector.class "placement-card__badge--reading" ]
            , test "an ABSENT readingStatus shows 'Not recorded', not 'To Read'" <|
                -- ⛔ This asserted "To Read" and was pinning the defect as the
                -- contract. An absent status and `to_read` are different facts:
                -- the card defaulted one to the other, so a reader mid-book saw
                -- "To Read" and pressing Save wrote `to_read` over the real
                -- value. The same conflation also swallowed a status this build
                -- cannot parse, which is an ordinary deploy-skew window.
                \_ ->
                    Card.view noStatusModel
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.attribute
                                (Html.Attributes.attribute "data-testid" "reading-status-badge")
                            ]
                        |> Expect.all
                            [ Query.has [ Selector.text "Not recorded" ]
                            , Query.hasNot [ Selector.text "To Read" ]
                            ]
            , test "Completed status shows badge label 'Finished'" <|
                \_ ->
                    Card.view completedModel
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.attribute
                                (Html.Attributes.attribute "data-testid" "reading-status-badge")
                            ]
                        |> Query.has [ Selector.text "Finished" ]
            , test "Completed status badge has class 'placement-card__badge--completed'" <|
                \_ ->
                    Card.view completedModel
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.attribute
                                (Html.Attributes.attribute "data-testid" "reading-status-badge")
                            ]
                        |> Query.has [ Selector.class "placement-card__badge--completed" ]
            , test "Abandoned status shows badge label 'Abandoned'" <|
                \_ ->
                    Card.view abandonedModel
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.attribute
                                (Html.Attributes.attribute "data-testid" "reading-status-badge")
                            ]
                        |> Query.has [ Selector.text "Abandoned" ]
            , test "Abandoned status badge has class 'placement-card__badge--abandoned'" <|
                \_ ->
                    Card.view abandonedModel
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.attribute
                                (Html.Attributes.attribute "data-testid" "reading-status-badge")
                            ]
                        |> Query.has [ Selector.class "placement-card__badge--abandoned" ]
            ]
        , describe "reading progress text"
            [ test "Reading status with currentPage = Just 80 shows '80' in progress text" <|
                \_ ->
                    Card.view readingWithPageModel
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.attribute
                                (Html.Attributes.attribute "data-testid" "reading-progress")
                            ]
                        |> Query.has [ Selector.text "80" ]
            ]
        , describe "finished-at progress text"
            [ test "Completed placement with finishedAt renders text containing 'Finished'" <|
                \_ ->
                    Card.view completedModel
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.attribute
                                (Html.Attributes.attribute "data-testid" "finished-at")
                            ]
                        |> Query.has [ Selector.text "Finished" ]
            , test "Completed placement with finishedAt '2026-03-15T10:00:00Z' renders formatted date" <|
                \_ ->
                    Card.view completedModel
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.attribute
                                (Html.Attributes.attribute "data-testid" "finished-at")
                            ]
                        |> Query.has [ Selector.text "15 Mar 2026" ]
            ]
        , describe "SaveClicked OutMsg"
            [ test "SaveClicked emits ProgressUpdateRequested" <|
                \_ ->
                    let
                        model =
                            Card.init
                                { testPlacement
                                    | readingStatus = Just Reading
                                    , currentPage = Just 42
                                }

                        ( _, outMsg ) =
                            Card.update Card.SaveClicked model
                    in
                    Expect.equal Card.ProgressUpdateRequested outMsg
            ]
        ]
