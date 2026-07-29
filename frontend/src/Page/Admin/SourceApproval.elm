module Page.Admin.SourceApproval exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , StatusFilter(..)
    , init
    , statusFilterToString
    , update
    , view
    )

{-| Admin Source Approval page.

Displays sources in a filterable, paginated list. The owner can approve
or reject pending sources.

-}

import Api exposing (AdminSource, AdminSourcesResponse)
import Html exposing (Html, button, div, h1, p, span, table, tbody, td, text, th, thead, tr)
import Html.Attributes exposing (class, disabled)
import Html.Events exposing (onClick)
import Http
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


type StatusFilter
    = All
    | Pending
    | Approved
    | Rejected


type alias Model =
    { sources : RemoteData Http.Error AdminSourcesResponse
    , statusFilter : StatusFilter
    , page : Int
    , actionInProgress : Maybe String
    , actionError : Maybe String
    }


type Msg
    = SourcesReceived (Result Http.Error AdminSourcesResponse)
    | SetStatusFilter StatusFilter
    | PageChanged Int
    | ApproveClicked String
    | RejectClicked String
    | ApproveCompleted String (Result Http.Error AdminSource)
    | RejectCompleted String (Result Http.Error AdminSource)


type OutMsg
    = NoOut
    | SessionExpired


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    let
        model =
            { sources = Loading
            , statusFilter = All
            , page = 1
            , actionInProgress = Nothing
            , actionError = Nothing
            }
    in
    ( model, fetchSources model maybeToken )


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        SourcesReceived result ->
            case result of
                Ok response ->
                    ( { model | sources = Success response }, Cmd.none, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | sources = Failure err }, Cmd.none, NoOut )

        SetStatusFilter filter ->
            let
                newModel =
                    { model | statusFilter = filter, page = 1, sources = Loading }
            in
            ( newModel, fetchSources newModel maybeToken, NoOut )

        PageChanged newPage ->
            let
                newModel =
                    { model | page = newPage, sources = Loading }
            in
            ( newModel, fetchSources newModel maybeToken, NoOut )

        ApproveClicked sourceId ->
            case maybeToken of
                Just token ->
                    ( { model | actionInProgress = Just sourceId }
                    , Api.approveSource sourceId token (ApproveCompleted sourceId)
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        RejectClicked sourceId ->
            case maybeToken of
                Just token ->
                    ( { model | actionInProgress = Just sourceId }
                    , Api.rejectSource sourceId token (RejectCompleted sourceId)
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        ApproveCompleted sourceId result ->
            handleActionResult model sourceId result

        RejectCompleted sourceId result ->
            handleActionResult model sourceId result


handleActionResult : Model -> String -> Result Http.Error AdminSource -> ( Model, Cmd Msg, OutMsg )
handleActionResult model sourceId result =
    case result of
        Ok updatedSource ->
            let
                updatedSources =
                    case model.sources of
                        Success response ->
                            Success
                                { response
                                    | sources =
                                        List.map
                                            (\s ->
                                                if s.id == sourceId then
                                                    updatedSource

                                                else
                                                    s
                                            )
                                            response.sources
                                }

                        other ->
                            other
            in
            ( { model | sources = updatedSources, actionInProgress = Nothing, actionError = Nothing }, Cmd.none, NoOut )

        Err err ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
                ( { model | actionInProgress = Nothing, actionError = Just "Action failed. Please try again." }, Cmd.none, NoOut )


fetchSources : Model -> Maybe String -> Cmd Msg
fetchSources model maybeToken =
    case maybeToken of
        Just token ->
            Api.getAdminSources
                { status = statusFilterToString model.statusFilter
                , page = model.page
                }
                token
                SourcesReceived

        Nothing ->
            Cmd.none


statusFilterToString : StatusFilter -> Maybe String
statusFilterToString filter =
    case filter of
        All ->
            Nothing

        Pending ->
            -- The server's value, not the UI's word for it. Sending "pending" matched no row, so
            -- the Pending tab silently showed an empty list.
            Just "pending_review"

        Approved ->
            Just "approved"

        Rejected ->
            -- `reject_source/1` transitions to **"dismissed"** (`discovery.ex:229`), not
            -- "rejected" — the UI keeps the operator's word while sending the server's.
            Just "dismissed"



-- VIEW


view : Model -> Html Msg
view model =
    div [ class "page page--admin" ]
        [ h1 [ class "page__title admin__title" ] [ text "Source Approval" ]
        , p [ class "admin__subtitle" ]
            [ text "Review and approve data sources for the catalogue." ]
        , case model.actionError of
            Just err ->
                p [ class "admin__error" ] [ text err ]

            Nothing ->
                text ""
        , viewFilterTabs model.statusFilter
        , viewContent model
        ]


viewFilterTabs : StatusFilter -> Html Msg
viewFilterTabs active =
    div [ class "admin__tabs" ]
        [ filterTab All "All" active
        , filterTab Pending "Pending" active
        , filterTab Approved "Approved" active
        , filterTab Rejected "Rejected" active
        ]


filterTab : StatusFilter -> String -> StatusFilter -> Html Msg
filterTab filter label active =
    button
        [ class
            (if filter == active then
                "admin__tab admin__tab--active"

             else
                "admin__tab"
            )
        , onClick (SetStatusFilter filter)
        ]
        [ text label ]


viewContent : Model -> Html Msg
viewContent model =
    case model.sources of
        NotAsked ->
            text ""

        Loading ->
            div [ class "loading" ] [ text "Loading sources..." ]

        Failure _ ->
            p [ class "error" ] [ text "Failed to load sources. Please try again." ]

        Success response ->
            if List.isEmpty response.sources then
                p [ class "admin__empty" ] [ text "No sources found." ]

            else
                div []
                    [ viewSourcesTable model.actionInProgress response.sources
                    , viewPagination response
                    ]


viewSourcesTable : Maybe String -> List AdminSource -> Html Msg
viewSourcesTable actionInProgress sources =
    table [ class "metrics-table" ]
        [ thead []
            [ tr []
                [ th [] [ text "Name" ]
                , th [] [ text "URL" ]
                , th [] [ text "Type" ]
                , th [] [ text "Confidence" ]
                , th [] [ text "Status" ]
                , th [] [ text "Actions" ]
                ]
            ]
        , tbody []
            (List.map (viewSourceRow actionInProgress) sources)
        ]


viewSourceRow : Maybe String -> AdminSource -> Html Msg
viewSourceRow actionInProgress source =
    let
        isProcessing =
            actionInProgress == Just source.id
    in
    tr []
        [ td [] [ text source.name ]
        , td [ class "admin__url-cell" ] [ text source.url ]
        , td [] [ text source.sourceType ]
        , td [] [ text (String.fromFloat source.confidenceScore) ]
        , td [] [ viewStatusBadge source.status ]
        , td []
            -- ⛔ Was `== "pending"`. The server's status is **`"pending_review"`**
            -- (`Stacks.Discovery` writes it on create and gates both transitions on it), so this
            -- comparison never matched and the Approve/Reject buttons NEVER rendered. The page
            -- showed an "Actions" column that was always empty.
            --
            -- ⚠️ It survived because the page was unreachable at all (#303): the admin pipeline
            -- 401'd every request, so nobody ever saw a row to notice the missing buttons. Two
            -- independent defects stacked, and fixing only the auth one would have produced a
            -- page that loads and still cannot be used.
            (if source.status == "pending_review" then
                -- testIds because the filter tab above is also a button reading "Approved", so a
                -- prose selector cannot tell the two apart — a test asserting the buttons are
                -- ABSENT passes on the tab's label instead. That is #302's defect class exactly.
                [ button
                    [ class "btn btn--primary btn--sm"
                    , onClick (ApproveClicked source.id)
                    , disabled isProcessing
                    , testId "source-approve"
                    ]
                    [ text "Approve" ]
                , button
                    [ class "btn btn--danger btn--sm"
                    , onClick (RejectClicked source.id)
                    , disabled isProcessing
                    , testId "source-reject"
                    ]
                    [ text "Reject" ]
                ]

             else
                [ text "" ]
            )
        ]


viewStatusBadge : String -> Html Msg
viewStatusBadge status =
    let
        badgeClass =
            case status of
                "approved" ->
                    "status-badge--healthy"

                "rejected" ->
                    "status-badge--broken"

                "pending" ->
                    "status-badge--degraded"

                _ ->
                    ""
    in
    span [ class ("status-badge " ++ badgeClass) ] [ text status ]


viewPagination : AdminSourcesResponse -> Html Msg
viewPagination response =
    let
        totalPages =
            ceiling (toFloat response.total / toFloat response.perPage)

        hasPrev =
            response.page > 1

        hasNext =
            response.page < totalPages
    in
    if totalPages <= 1 then
        text ""

    else
        div [ class "admin__pagination" ]
            [ if hasPrev then
                button
                    [ class "btn btn--secondary btn--sm"
                    , onClick (PageChanged (response.page - 1))
                    ]
                    [ text "Previous" ]

              else
                text ""
            , span [ class "admin__page-info" ]
                [ text ("Page " ++ String.fromInt response.page ++ " of " ++ String.fromInt totalPages) ]
            , if hasNext then
                button
                    [ class "btn btn--secondary btn--sm"
                    , onClick (PageChanged (response.page + 1))
                    ]
                    [ text "Next" ]

              else
                text ""
            ]
