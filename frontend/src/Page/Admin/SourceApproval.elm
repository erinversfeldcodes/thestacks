module Page.Admin.SourceApproval exposing
    ( Model
    , Msg
    , init
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


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg )
update msg model maybeToken =
    case msg of
        SourcesReceived result ->
            case result of
                Ok response ->
                    ( { model | sources = Success response }, Cmd.none )

                Err err ->
                    ( { model | sources = Failure err }, Cmd.none )

        SetStatusFilter filter ->
            let
                newModel =
                    { model | statusFilter = filter, page = 1, sources = Loading }
            in
            ( newModel, fetchSources newModel maybeToken )

        PageChanged newPage ->
            let
                newModel =
                    { model | page = newPage, sources = Loading }
            in
            ( newModel, fetchSources newModel maybeToken )

        ApproveClicked sourceId ->
            case maybeToken of
                Just token ->
                    ( { model | actionInProgress = Just sourceId }
                    , Api.approveSource sourceId token (ApproveCompleted sourceId)
                    )

                Nothing ->
                    ( model, Cmd.none )

        RejectClicked sourceId ->
            case maybeToken of
                Just token ->
                    ( { model | actionInProgress = Just sourceId }
                    , Api.rejectSource sourceId token (RejectCompleted sourceId)
                    )

                Nothing ->
                    ( model, Cmd.none )

        ApproveCompleted sourceId result ->
            handleActionResult model sourceId result

        RejectCompleted sourceId result ->
            handleActionResult model sourceId result


handleActionResult : Model -> String -> Result Http.Error AdminSource -> ( Model, Cmd Msg )
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
            ( { model | sources = updatedSources, actionInProgress = Nothing, actionError = Nothing }, Cmd.none )

        Err _ ->
            ( { model | actionInProgress = Nothing, actionError = Just "Action failed. Please try again." }, Cmd.none )


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
            Just "pending"

        Approved ->
            Just "approved"

        Rejected ->
            Just "rejected"



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
            (if source.status == "pending" then
                [ button
                    [ class "btn btn--primary btn--sm"
                    , onClick (ApproveClicked source.id)
                    , disabled isProcessing
                    ]
                    [ text "Approve" ]
                , button
                    [ class "btn btn--danger btn--sm"
                    , onClick (RejectClicked source.id)
                    , disabled isProcessing
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
