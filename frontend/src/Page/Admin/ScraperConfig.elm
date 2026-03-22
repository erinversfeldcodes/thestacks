module Page.Admin.ScraperConfig exposing
    ( Model
    , Msg(..)
    , init
    , update
    , view
    )

{-| Admin Scraper Config page.

Read-only dashboard showing scraper/source health status.
No edit functionality - just a monitoring view.

-}

import Api exposing (SourceHealth)
import Html exposing (Html, div, h1, p, span, table, tbody, td, text, th, thead, tr)
import Html.Attributes exposing (class)
import Http
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { sourceHealth : RemoteData Http.Error (List SourceHealth)
    }


type Msg
    = SourceHealthReceived (Result Http.Error (List SourceHealth))


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    let
        model =
            { sourceHealth = Loading }
    in
    case maybeToken of
        Just token ->
            ( model, Api.getSourceHealth token SourceHealthReceived )

        Nothing ->
            ( { sourceHealth = NotAsked }, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        SourceHealthReceived result ->
            case result of
                Ok sources ->
                    ( { model | sourceHealth = Success sources }, Cmd.none )

                Err err ->
                    ( { model | sourceHealth = Failure err }, Cmd.none )



-- VIEW


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
                viewHealthTable sources


viewHealthTable : List SourceHealth -> Html Msg
viewHealthTable sources =
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
            (List.map viewHealthRow sources)
        ]


viewHealthRow : SourceHealth -> Html Msg
viewHealthRow source =
    tr []
        [ td [] [ text source.name ]
        , td [] [ text source.sourceType ]
        , td [] [ viewStatusBadge source.status ]
        , td [] [ text (String.fromInt source.consecutiveFailures) ]
        , td [] [ text (Maybe.withDefault "-" source.lastSuccess) ]
        , td [] [ text (Maybe.withDefault "-" source.lastFailure) ]
        ]


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
    span [ class ("status-badge " ++ badgeClass) ] [ text status ]
