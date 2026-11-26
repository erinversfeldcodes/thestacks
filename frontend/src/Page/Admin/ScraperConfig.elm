module Page.Admin.ScraperConfig exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

{-| Admin Scraper Config page.

Read-only dashboard showing scraper/source health status.
No edit functionality - just a monitoring view.

-}

import Api exposing (SourceHealth)
import Effect
import Html exposing (Html, div, h1, p, span, table, tbody, td, text, th, thead, tr)
import Html.Attributes exposing (class)
import Http
import Task
import Time
import Types.RemoteData exposing (RemoteData(..))
import Util.Label as Label
import Util.RelativeTime as RelativeTime


type alias Model =
    { sourceHealth : RemoteData Http.Error (List SourceHealth)
    , now : Maybe Time.Posix
    }


type Msg
    = SourceHealthReceived (Result Http.Error (List SourceHealth))
    | SessionExpiryDetected
    | GotNow Time.Posix


type OutMsg
    = NoOut
    | SessionExpired


init : Maybe Api.Credentials -> ( Model, Cmd Msg )
init maybeToken =
    let
        model =
            { sourceHealth = Loading, now = Nothing }
    in
    case maybeToken of
        Just token ->
            ( model
            , Cmd.batch
                [ Effect.perform
                    (Effect.authed Api.sourceHealthRequest
                        token
                        { onExpired = SessionExpiryDetected
                        , onResponse = Api.resolveJson Api.sourceHealthListDecoder >> SourceHealthReceived
                        }
                    )
                , Task.perform GotNow Time.now
                ]
            )

        Nothing ->
            ( { sourceHealth = NotAsked, now = Nothing }, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        SessionExpiryDetected ->
            ( model, Cmd.none, SessionExpired )

        GotNow posix ->
            ( { model | now = Just posix }, Cmd.none, NoOut )

        SourceHealthReceived result ->
            case result of
                Ok sources ->
                    ( { model | sourceHealth = Success sources }, Cmd.none, NoOut )

                Err err ->
                    -- ⚠️ KEPT, and it is NOT the residue an authed page sheds.
                    -- `needsAdminElevation` matches 401 OR 403; the plan now claims
                    -- the 401, so what still arrives here is the 403 — an operator
                    -- whose 30-minute elevation window ran out. Routing that to the
                    -- gate is this branch's whole job, and no plan can do it: a 403
                    -- is not an ended session.
                    if Api.needsAdminElevation err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | sourceHealth = Failure err }, Cmd.none, NoOut )


view : Model -> Html Msg
view model =
    div [ class "page page--admin" ]
        [ h1 [ class "page__title admin__title" ] [ text "Scraper Health" ]
        , p [ class "admin__subtitle" ]
            [ text "Monitor scraper and source health at a glance." ]
        , viewContent model
        ]


viewContent : Model -> Html Msg
viewContent model =
    case model.sourceHealth of
        NotAsked ->
            text ""

        Loading ->
            div [ class "loading" ] [ text "Loading source health..." ]

        Failure _ ->
            p [ class "error" ] [ text "Failed to load source health. Please try again." ]

        Success sources ->
            if List.isEmpty sources then
                p [ class "admin__empty" ] [ text "No sources configured." ]

            else
                viewHealthTable model.now sources


viewHealthTable : Maybe Time.Posix -> List SourceHealth -> Html Msg
viewHealthTable now sources =
    table [ class "metrics-table" ]
        [ thead []
            [ tr []
                [ th [] [ text "Source" ]
                , th [] [ text "Type" ]
                , th [] [ text "Status" ]
                , th [] [ text "Consecutive Failures" ]
                , th [] [ text "Last Success" ]
                , th [] [ text "Last Failure" ]
                ]
            ]
        , tbody []
            (List.map (viewHealthRow now) sources)
        ]


viewHealthRow : Maybe Time.Posix -> SourceHealth -> Html Msg
viewHealthRow now source =
    tr []
        [ td [] [ text source.name ]
        , td [] [ text source.sourceType ]
        , td [] [ viewStatusBadge source.status ]
        , td [] [ text (String.fromInt source.consecutiveFailures) ]
        , td [] [ text (relativeOrDash now source.lastSuccess) ]
        , td [] [ text (relativeOrDash now source.lastFailure) ]
        ]


{-| A stored timestamp as relative-time copy, or an em-dash when there is none.
Before `now` has loaded it shows the date alone rather than the raw timestamp, so
a microsecond-precision storage literal never reaches the operator's eye.
-}
relativeOrDash : Maybe Time.Posix -> Maybe String -> String
relativeOrDash now maybeIso =
    case maybeIso of
        Nothing ->
            "—"

        Just iso ->
            case now of
                Just posix ->
                    RelativeTime.relative posix iso

                Nothing ->
                    String.left 10 iso


viewStatusBadge : String -> Html Msg
viewStatusBadge status =
    let
        badgeClass =
            case status of
                "healthy" ->
                    "status-badge--healthy"

                "degraded" ->
                    "status-badge--degraded"

                "broken" ->
                    "status-badge--broken"

                _ ->
                    ""
    in
    span [ class ("status-badge " ++ badgeClass) ] [ text (Label.humanize status) ]
