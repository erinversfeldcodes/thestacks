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
            , test "Reading status badge has class 'placement-card__badge--reading'" <|
                \_ ->
                    Card.view readingModel
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.attribute
                                (Html.Attributes.attribute "data-testid" "reading-status-badge")
                            ]
                        |> Query.has [ Selector.class "placement-card__badge--reading" ]
            , test "Nothing readingStatus shows badge label 'To Read'" <|
                \_ ->
                    Card.view noStatusModel
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.attribute
                                (Html.Attributes.attribute "data-testid" "reading-status-badge")
                            ]
                        |> Query.has [ Selector.text "To Read" ]
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
