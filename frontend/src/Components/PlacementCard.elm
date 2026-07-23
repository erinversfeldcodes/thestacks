module Components.PlacementCard exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , badgeDomId
    , hideTitle
    , init
    , stopSaving
    , update
    , view
    )

{-| PlacementCard renders a placement's reading status badge and page progress indicator.

Clicking the badge opens an inline form to update reading status and current page.
Updates are emitted via OutMsg so the parent can call the API.

The form stays OPEN after Save (with the Save button disabled and a "Saving…"
label) until the host reports the outcome: on success the host re-inits the card
(closing the form), on failure the host clears the saving flag with `stopSaving`
so the reader can correct the draft, which is preserved.

-}

import Html exposing (Html, button, div, input, label, option, select, span, text)
import Html.Attributes exposing (attribute, class, disabled, id, placeholder, selected, type_, value)
import Html.Events exposing (onClick, onInput)
import Types.Placement exposing (Placement, ReadingStatus(..))
import Util.TestId exposing (testId)


type alias Model =
    { placement : Placement
    , editing : Bool
    , saving : Bool
    , showTitle : Bool
    , draftStatus : ReadingStatus
    , draftPage : String
    }


type OutMsg
    = NoOut
    | ProgressUpdateRequested
    | EditClosed


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
    , saving = False
    , showTitle = True
    , draftStatus = Maybe.withDefault ToRead placement.readingStatus
    , draftPage = placement.currentPage |> Maybe.map String.fromInt |> Maybe.withDefault ""
    }


{-| Suppress the book-title header — used on the BookDetail overlay, where the
book identity is already the page context (the pile shows it, one card per book).
-}
hideTitle : Model -> Model
hideTitle model =
    { model | showTitle = False }


{-| Clear the in-flight save flag, keeping the form open and the draft intact.
The host calls this when a save fails so the reader can correct and retry.
-}
stopSaving : Model -> Model
stopSaving model =
    { model | saving = False }


{-| The stable DOM id of a placement's status badge, so the host can return
focus to it (Browser.Dom.focus) when the edit form closes.
-}
badgeDomId : Placement -> String
badgeDomId placement =
    "reading-status-badge-" ++ placement.id


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
            -- Keep the form OPEN and mark it saving. The host fires the API and,
            -- on success, re-inits the card (closing the form); on failure it
            -- calls `stopSaving`, leaving the form open with the draft intact.
            ( { model | saving = True }
            , ProgressUpdateRequested
            )

        CancelClicked ->
            ( { model
                | editing = False
                , saving = False
                , draftStatus = Maybe.withDefault ToRead model.placement.readingStatus
                , draftPage = model.placement.currentPage |> Maybe.map String.fromInt |> Maybe.withDefault ""
              }
            , EditClosed
            )


view : Model -> Html Msg
view model =
    div [ class "placement-card", testId "placement-card" ]
        [ viewHeader model
        , viewStatusBadge model
        , viewProgress model.placement
        , if model.editing then
            viewEditForm model

          else
            text ""
        ]


viewHeader : Model -> Html Msg
viewHeader model =
    if model.showTitle then
        case model.placement.book of
            Just book ->
                div [ class "placement-card__title", testId "placement-card-title" ]
                    [ text book.title ]

            Nothing ->
                text ""

    else
        text ""


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
        , id (badgeDomId model.placement)
        , onClick BadgeClicked
        , testId "reading-status-badge"
        , attribute "aria-expanded"
            (if model.editing then
                "true"

             else
                "false"
            )
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
        [ label [ class "placement-card__field" ]
            -- The <select> is nested inside its <label>, which associates them
            -- programmatically (implicit labelling) without needing id/for.
            [ span [ class "placement-card__label" ] [ text "Status" ]
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
            label [ class "placement-card__field" ]
                [ span [ class "placement-card__label" ] [ text "Current page" ]
                , input
                    [ class "placement-card__input"
                    , type_ "number"
                    , value model.draftPage
                    , placeholder "0"
                    , onInput PageChanged
                    , testId "current-page-input"

                    -- Links the input to the host's inline save-error element
                    -- (id "progress-error"), so a screen reader announces "that
                    -- page is past the end of the book" against this field.
                    , attribute "aria-describedby" "progress-error"
                    ]
                    []
                ]

          else
            text ""
        , div [ class "placement-card__actions" ]
            [ button
                [ class "btn btn--primary"
                , onClick SaveClicked
                , disabled model.saving
                , testId "save-progress-btn"
                ]
                [ text
                    (if model.saving then
                        "Saving…"

                     else
                        "Save"
                    )
                ]
            , button
                [ class "btn btn--ghost"
                , onClick CancelClicked
                , disabled model.saving
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
