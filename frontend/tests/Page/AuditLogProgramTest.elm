module Page.AuditLogProgramTest exposing (suite)

{-| Program tests for Page.Settings.AuditLog using elm-program-test.

Exercises the audit-log page lifecycle: loading, success (renders the
list of entries), error, and empty states.

-}

import Api
import Http
import Json.Encode as Encode
import Page.Settings.AuditLog as AuditLog exposing (Msg(..))
import ProgramTest exposing (ProgramDefinition, SimulatedEffect)
import SimulatedEffect.Cmd
import SimulatedEffect.Http
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector


suite : Test
suite =
    describe "Page.Settings.AuditLog (ProgramTest)"
        [ showsLoadingState
        , loadAndDisplayEntries
        , showsErrorState
        , showsEmptyState
        ]


start : ProgramTest.ProgramTest AuditLog.Model AuditLog.Msg (SimulatedEffect AuditLog.Msg)
start =
    ProgramTest.start () (program (Just "test-token"))


program : Maybe String -> ProgramDefinition () AuditLog.Model AuditLog.Msg (SimulatedEffect AuditLog.Msg)
program maybeToken =
    ProgramTest.createElement
        { init =
            \() ->
                let
                    ( model, _ ) =
                        AuditLog.init maybeToken
                in
                ( model, initEffects maybeToken )
        , update =
            \msg model ->
                let
                    ( newModel, _, _ ) =
                        AuditLog.update msg model maybeToken
                in
                ( newModel, SimulatedEffect.Cmd.none )
        , view = AuditLog.view
        }
        |> ProgramTest.withSimulatedEffects identity


initEffects : Maybe String -> SimulatedEffect AuditLog.Msg
initEffects maybeToken =
    case maybeToken of
        Just token ->
            SimulatedEffect.Http.request
                { method = "GET"
                , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                , url = "/api/settings/audit-log?page=1"
                , body = SimulatedEffect.Http.emptyBody
                , expect = SimulatedEffect.Http.expectJson AuditLog.AuditLogReceived Api.auditLogResponseDecoder
                , timeout = Nothing
                , tracker = Nothing
                }

        Nothing ->
            SimulatedEffect.Cmd.none


sampleJson : String
sampleJson =
    Encode.encode 0
        (Encode.object
            [ ( "entries"
              , Encode.list identity
                    [ entryJson "e1" "user.login" "user" "2026-07-09T10:00:00Z"
                    , entryJson "e2" "user.export_requested" "user" "2026-07-08T09:00:00Z"
                    ]
              )
            , ( "total", Encode.int 2 )
            , ( "page", Encode.int 1 )
            , ( "per_page", Encode.int 25 )
            ]
        )


emptyJson : String
emptyJson =
    Encode.encode 0
        (Encode.object
            [ ( "entries", Encode.list identity [] )
            , ( "total", Encode.int 0 )
            , ( "page", Encode.int 1 )
            , ( "per_page", Encode.int 25 )
            ]
        )


entryJson : String -> String -> String -> String -> Encode.Value
entryJson id action resourceType occurredAt =
    Encode.object
        [ ( "id", Encode.string id )
        , ( "action", Encode.string action )
        , ( "resource_type", Encode.string resourceType )
        , ( "resource_id", Encode.null )
        , ( "occurred_at", Encode.string occurredAt )
        , ( "metadata", Encode.object [] )
        ]


showsLoadingState : Test
showsLoadingState =
    test "loading_state: shows loading message before data arrives" <|
        \() ->
            start
                |> ProgramTest.expectViewHas
                    [ Selector.text "Loading your audit log..." ]


loadAndDisplayEntries : Test
loadAndDisplayEntries =
    test "load_entries: init fetches audit log -> renders entry rows" <|
        \() ->
            start
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/settings/audit-log?page=1"
                    sampleJson
                |> ProgramTest.ensureViewHas
                    [ Selector.text "user.login" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "user.export_requested" ]


showsErrorState : Test
showsErrorState =
    test "error_state: shows error message on HTTP failure" <|
        \() ->
            start
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/settings/audit-log?page=1"
                    Http.NetworkError_
                |> ProgramTest.expectViewHas
                    [ Selector.text "Failed to load your audit log. Please try again." ]


showsEmptyState : Test
showsEmptyState =
    test "empty_state: shows message when there are no entries" <|
        \() ->
            start
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/settings/audit-log?page=1"
                    emptyJson
                |> ProgramTest.expectViewHas
                    [ Selector.text "No audit entries yet." ]
