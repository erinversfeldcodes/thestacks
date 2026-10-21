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
import Types.Placement exposing (Placement, ReadingStatus(..), parseReadingStatus)
import Util.TestId exposing (testId)


type alias Model =
    { placement : Placement
    , editing : Bool
    , saving : Bool
    , showTitle : Bool
    , draftStatus : Maybe ReadingStatus
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
    , draftStatus = placement.readingStatus
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
            -- ⛔ `parseReadingStatus` rather than a total String -> ReadingStatus
            -- function, and the difference is the whole defect once more. The
            -- previous helper ended in `_ -> ToRead`, so ANY value the select
            -- could emit that this build does not recognise — the placeholder's
            -- empty string included — became `Just ToRead`, which re-enables
            -- Save and writes `to_read` over whatever the server held. That is
            -- the original defect arriving through a different door.
            --
            -- ⚠️ What stood between that and a destructive write was the
            -- `disabled` attribute on the placeholder `<option>`, which is a
            -- thin guarantee to hang a write on. Now an unrecognised value
            -- yields `Nothing`, so `draftStatus` stays empty, Save stays
            -- disabled, and both host guards still refuse to send.
            ( { model | draftStatus = parseReadingStatus s }, NoOut )

        PageChanged s ->
            ( { model | draftPage = s }, NoOut )

        SaveClicked ->
            ( { model | saving = True }
            , ProgressUpdateRequested
            )

        CancelClicked ->
            ( { model
                | editing = False
                , saving = False
                , draftStatus = model.placement.readingStatus
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
        -- ⛔ An unrecorded status is rendered as unrecorded, NOT as "To Read".
        -- `Maybe.withDefault ToRead` here was the original defect re-entering
        -- through a narrower door: three input cases reach the decoder — key
        -- absent, parseable, and present-but-unparseable — and only the first
        -- two are distinguishable afterwards, so a status this build cannot
        -- parse rendered as a specific, wrong, reader-visible claim.
        --
        -- ⚠️ Reachability is an ordinary deploy-skew window: the server adds a
        -- fifth status and ships before the SPA has the matching parse arm.
        -- This file already records the same hazard for the sibling field —
        -- see `formatToString`'s note that "a spelling these two disagree on
        -- round-trips as silence".
        --
        -- The page makes the opposite choice two files away for the same
        -- situation (`BookDetail` renders "Status unknown" rather than guess),
        -- and the project standard is that an absent value beats a lying one.
        ( label_, cls ) =
            case model.placement.readingStatus of
                Nothing ->
                    ( "Not recorded", "placement-card__badge--unrecorded" )

                Just ToRead ->
                    ( "To Read", "placement-card__badge--to-read" )

                Just Reading ->
                    ( "Reading", "placement-card__badge--reading" )

                Just Completed ->
                    ( "Finished", "placement-card__badge--completed" )

                Just Abandoned ->
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
            [ span [ class "placement-card__label" ] [ text "Status" ]
            , select
                [ class "placement-card__select"
                , onInput StatusChanged
                , testId "status-select"
                ]
                -- ⚠️ A placeholder option exists ONLY while no status is
                -- recorded, and it is not selectable back into. Without it the
                -- browser would show the first real option as selected and the
                -- reader would believe a status had been chosen for them.
                ((case model.draftStatus of
                    Nothing ->
                        [ option
                            [ value "", selected True, disabled True ]
                            [ text "Not recorded — choose one" ]
                        ]

                    Just _ ->
                        []
                 )
                    ++ [ option [ value "to_read", selected (model.draftStatus == Just ToRead) ] [ text "To Read" ]
                       , option [ value "reading", selected (model.draftStatus == Just Reading) ] [ text "Reading" ]
                       , option [ value "completed", selected (model.draftStatus == Just Completed) ] [ text "Finished" ]
                       , option [ value "abandoned", selected (model.draftStatus == Just Abandoned) ] [ text "Abandoned" ]
                       ]
                )
            ]
        , if model.draftStatus == Just Reading then
            label [ class "placement-card__field" ]
                [ span [ class "placement-card__label" ] [ text "Current page" ]
                , input
                    [ class "placement-card__input"
                    , type_ "number"
                    , value model.draftPage
                    , placeholder "0"
                    , onInput PageChanged
                    , testId "current-page-input"
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

                -- ⛔ Disabled until a status is actually chosen. This is the
                -- destructive half of the original defect: `init` used to seed
                -- `draftStatus` with `ToRead`, so opening the card and pressing
                -- Save without touching the dropdown WROTE `to_read` over
                -- whatever the server held — including over a status this build
                -- could not parse. The server requires `reading_status` on a
                -- progress update (422 without it), so the client cannot omit
                -- it; refusing to send an un-chosen one is the honest answer.
                , disabled (model.saving || model.draftStatus == Nothing)
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



-- `readingStatusFromString` lived here and is deliberately gone rather than
-- kept for a future caller: a total `String -> ReadingStatus` cannot represent
-- "not a status I recognise", so every caller it ever had would have to invent
-- one. `Types.Placement.parseReadingStatus` returns a `Maybe` and is the single
-- place this mapping belongs; it also handled "to_read" explicitly, which the
-- deleted version only got right by falling through to its default.


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
