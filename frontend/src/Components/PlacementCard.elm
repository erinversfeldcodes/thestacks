module Components.PlacementCard exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

{-| PlacementCard renders a placement's reading status badge and page progress indicator.

Clicking the badge opens an inline form to update reading status and current page.
Updates are emitted via OutMsg so the parent can call the API.

-}

import Html exposing (Html, button, div, input, label, option, select, span, text)
import Html.Attributes exposing (attribute, class, placeholder, selected, type_, value)
import Html.Events exposing (onClick, onInput)
import Types.Placement exposing (Placement, ReadingStatus(..))
import Util.TestId exposing (testId)


type alias Model =
    { placement : Placement
    , editing : Bool
    , draftStatus : ReadingStatus
    , draftPage : String
    }


type OutMsg
    = NoOut
    | ProgressUpdateRequested


type Msg
    = BadgeClicked
    | StatusChanged String
    | PageChanged String
    | SaveClicked
    | CancelClicked


init : Placement -> Model
init placement =
    { placement = placement
    , editing = False
    , draftStatus = Maybe.withDefault ToRead placement.readingStatus
    , draftPage = placement.currentPage |> Maybe.map String.fromInt |> Maybe.withDefault ""
    }


update : Msg -> Model -> ( Model, OutMsg )
update msg model =
    case msg of
        BadgeClicked ->
            ( { model | editing = True }, NoOut )

        StatusChanged s ->
            ( { model | draftStatus = readingStatusFromString s }, NoOut )

        PageChanged s ->
            ( { model | draftPage = s }, NoOut )

        SaveClicked ->
            ( { model | editing = False }
            , ProgressUpdateRequested
            )

        CancelClicked ->
            ( { model
                | editing = False
                , draftStatus = Maybe.withDefault ToRead model.placement.readingStatus
                , draftPage = model.placement.currentPage |> Maybe.map String.fromInt |> Maybe.withDefault ""
              }
            , NoOut
            )


view : Model -> Html Msg
view model =
    div [ class "placement-card", testId "placement-card" ]
        [ viewStatusBadge model
        , viewProgress model.placement
        , if model.editing then
            viewEditForm model

          else
            text ""
        ]


viewStatusBadge : Model -> Html Msg
viewStatusBadge model =
    let
        status =
            Maybe.withDefault ToRead model.placement.readingStatus

        ( label_, cls ) =
            case status of
                ToRead ->
                    ( "To Read", "placement-card__badge--to-read" )

                Reading ->
                    ( "Reading", "placement-card__badge--reading" )

                Completed ->
                    ( "Finished", "placement-card__badge--completed" )

                Abandoned ->
                    ( "Abandoned", "placement-card__badge--abandoned" )
    in
    button
        [ class ("placement-card__badge " ++ cls)
        , onClick BadgeClicked
        , testId "reading-status-badge"
        , attribute "aria-label" ("Reading status: " ++ label_ ++ ". Click to update.")
        ]
        [ text label_ ]


viewProgress : Placement -> Html msg
viewProgress placement =
    case placement.readingStatus of
        Just Reading ->
            case placement.currentPage of
                Just current ->
                    let
                        pageCount =
                            placement.book
                                |> Maybe.andThen .primaryEdition
                                |> Maybe.andThen .pageCount

                        progressText =
                            case pageCount of
                                Just total ->
                                    "p. " ++ String.fromInt current ++ " / " ++ String.fromInt total

                                Nothing ->
                                    "p. " ++ String.fromInt current
                    in
                    span [ class "placement-card__progress", testId "reading-progress" ]
                        [ text progressText ]

                Nothing ->
                    text ""

        Just Completed ->
            let
                finishedText =
                    case placement.finishedAt of
                        Just iso ->
                            "Finished · " ++ formatIsoDate iso

                        Nothing ->
                            "Finished"
            in
            span [ class "placement-card__progress", testId "finished-at" ]
                [ text finishedText ]

        _ ->
            text ""


viewEditForm : Model -> Html Msg
viewEditForm model =
    div [ class "placement-card__edit-form", testId "reading-status-form" ]
        [ div [ class "placement-card__field" ]
            [ label [ class "placement-card__label" ] [ text "Status" ]
            , select
                [ class "placement-card__select"
                , onInput StatusChanged
                , testId "status-select"
                ]
                [ option [ value "to_read", selected (model.draftStatus == ToRead) ] [ text "To Read" ]
                , option [ value "reading", selected (model.draftStatus == Reading) ] [ text "Reading" ]
                , option [ value "completed", selected (model.draftStatus == Completed) ] [ text "Finished" ]
                , option [ value "abandoned", selected (model.draftStatus == Abandoned) ] [ text "Abandoned" ]
                ]
            ]
        , if model.draftStatus == Reading then
            div [ class "placement-card__field" ]
                [ label [ class "placement-card__label" ] [ text "Current page" ]
                , input
                    [ class "placement-card__input"
                    , type_ "number"
                    , value model.draftPage
                    , placeholder "0"
                    , onInput PageChanged
                    , testId "current-page-input"
                    ]
                    []
                ]

          else
            text ""
        , div [ class "placement-card__actions" ]
            [ button
                [ class "btn btn--primary"
                , onClick SaveClicked
                , testId "save-progress-btn"
                ]
                [ text "Save" ]
            , button
                [ class "btn btn--ghost"
                , onClick CancelClicked
                , testId "cancel-progress-btn"
                ]
                [ text "Cancel" ]
            ]
        ]



-- HELPERS


readingStatusFromString : String -> ReadingStatus
readingStatusFromString s =
    case s of
        "reading" ->
            Reading

        "completed" ->
            Completed

        "abandoned" ->
            Abandoned

        _ ->
            ToRead


{-| Format an ISO 8601 date string to a human-readable date.
Parses YYYY-MM-DDThh:mm:ssZ and formats as "D Mon YYYY".
Falls back to the raw string if parsing fails.
-}
formatIsoDate : String -> String
formatIsoDate iso =
    case String.split "T" iso of
        datePart :: _ ->
            case String.split "-" datePart of
                [ yyyy, mm, dd ] ->
                    let
                        monthName =
                            case mm of
                                "01" ->
                                    "Jan"

                                "02" ->
                                    "Feb"

                                "03" ->
                                    "Mar"

                                "04" ->
                                    "Apr"

                                "05" ->
                                    "May"

                                "06" ->
                                    "Jun"

                                "07" ->
                                    "Jul"

                                "08" ->
                                    "Aug"

                                "09" ->
                                    "Sep"

                                "10" ->
                                    "Oct"

                                "11" ->
                                    "Nov"

                                "12" ->
                                    "Dec"

                                _ ->
                                    mm

                        day =
                            String.toInt dd
                                |> Maybe.map String.fromInt
                                |> Maybe.withDefault dd
                    in
                    day ++ " " ++ monthName ++ " " ++ yyyy

                _ ->
                    iso

        _ ->
            iso
