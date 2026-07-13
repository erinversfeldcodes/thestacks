module Page.GdprExportProgramTest exposing (suite)

{-| Program tests for the "Export My Data" flow on Page.Settings.Privacy
using elm-program-test.

Exercises the export lifecycle: clicking the button shows a loading message,
a successful (202) response confirms the export was queued, and an HTTP
failure surfaces an error message.

-}

import Http
import Page.Settings.Privacy as Privacy exposing (Msg(..))
import ProgramTest exposing (ProgramDefinition, SimulatedEffect)
import SimulatedEffect.Cmd
import SimulatedEffect.Http
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector


suite : Test
suite =
    describe "Page.Settings.Privacy — Export My Data (ProgramTest)"
        [ showsExportButton
        , showsLoadingOnClick
        , showsQueuedOnSuccess
        , showsErrorOnFailure
        ]


token : String
token =
    "test-token"


start : ProgramTest.ProgramTest Privacy.Model Privacy.Msg (SimulatedEffect Privacy.Msg)
start =
    ProgramTest.start () program


program : ProgramDefinition () Privacy.Model Privacy.Msg (SimulatedEffect Privacy.Msg)
program =
    ProgramTest.createElement
        { init =
            \() ->
                ( Privacy.init, SimulatedEffect.Cmd.none )
        , update =
            \msg model ->
                let
                    ( newModel, _, _ ) =
                        Privacy.update msg model (Just token)
                in
                ( newModel, effectsFor msg )
        , view = Privacy.view
        }
        |> ProgramTest.withSimulatedEffects identity


effectsFor : Privacy.Msg -> SimulatedEffect Privacy.Msg
effectsFor msg =
    case msg of
        UserClicksExport ->
            SimulatedEffect.Http.request
                { method = "POST"
                , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                , url = "/api/gdpr/export"
                , body = SimulatedEffect.Http.emptyBody
                , expect = SimulatedEffect.Http.expectWhatever GotExportResponse
                , timeout = Nothing
                , tracker = Nothing
                }

        _ ->
            SimulatedEffect.Cmd.none


showsExportButton : Test
showsExportButton =
    test "export_button: the export action is offered before any click" <|
        \() ->
            start
                |> ProgramTest.expectViewHas
                    [ Selector.text "Export My Data" ]


showsLoadingOnClick : Test
showsLoadingOnClick =
    test "loading_state: clicking export shows the preparing message" <|
        \() ->
            start
                |> ProgramTest.clickButton "Export My Data"
                |> ProgramTest.expectViewHas
                    [ Selector.text "Preparing your export…" ]


showsQueuedOnSuccess : Test
showsQueuedOnSuccess =
    test "success_state: a 202 response confirms the export was queued" <|
        \() ->
            start
                |> ProgramTest.clickButton "Export My Data"
                |> ProgramTest.simulateHttpOk "POST"
                    "/api/gdpr/export"
                    ""
                |> ProgramTest.expectViewHas
                    [ Selector.text "Export queued" ]


showsErrorOnFailure : Test
showsErrorOnFailure =
    test "error_state: an HTTP failure surfaces an error message" <|
        \() ->
            start
                |> ProgramTest.clickButton "Export My Data"
                |> ProgramTest.simulateHttpResponse "POST"
                    "/api/gdpr/export"
                    Http.NetworkError_
                |> ProgramTest.expectViewHas
                    [ Selector.text "We couldn't queue your export. Please try again." ]
