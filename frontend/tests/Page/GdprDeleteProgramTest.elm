module Page.GdprDeleteProgramTest exposing (suite)

{-| Program tests for the "Delete My Data" flow in Privacy's Danger Zone:
the type-to-confirm guard (submit enabled only on exactly "DELETE"),
the request lifecycle, the single-flight invariant (mid-flight edits
neither cancel nor re-enable), and the queued acknowledgement copy.
-}

import Api
import Expect
import Http
import Page.Settings.Privacy as Privacy exposing (Msg(..))
import ProgramTest exposing (ProgramDefinition, SimulatedEffect)
import SimulatedEffect.Cmd
import SimulatedEffect.Http
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers
import Types.RemoteData exposing (RemoteData(..))


suite : Test
suite =
    describe "Page.Settings.Privacy — Delete My Data / Danger Zone (ProgramTest)"
        [ showsDeleteEntryPoint
        , revealsConfirmationOnClick
        , showsDisabledCueBeforeConfirm
        , guardDisabledForLowercase
        , guardDisabledForTruncated
        , guardDisabledForTrailingSpace
        , guardEnabledForExactMatch
        , showsLoadingOnSubmit
        , locksInputWhileLoading
        , singleFlightBlocksSecondRequest
        , showsQueuedOnSuccess
        , emitsAccountDeletedOnSuccess
        , showsErrorOnFailure
        , cancelResetsTheFlow
        ]


token : String
token =
    "test-token"


{-| Test model: wraps Privacy's model and accumulates the OutMsgs it emits so
the farewell/logout OutMsg can be asserted.
-}
type alias Model =
    { privacy : Privacy.Model
    , outMsgs : List Privacy.OutMsg
    }


testInit : Model
testInit =
    { privacy = Privacy.init, outMsgs = [] }


start : ProgramTest.ProgramTest Model Privacy.Msg (SimulatedEffect Privacy.Msg)
start =
    ProgramTest.start () program


program : ProgramDefinition () Model Privacy.Msg (SimulatedEffect Privacy.Msg)
program =
    ProgramTest.createElement
        { init =
            \() ->
                ( testInit, SimulatedEffect.Cmd.none )
        , update =
            \msg model ->
                let
                    ( newPrivacy, _, outMsg ) =
                        Privacy.update msg model.privacy (Just token)
                in
                ( { model | privacy = newPrivacy, outMsgs = model.outMsgs ++ [ outMsg ] }
                , effectFor msg model.privacy newPrivacy
                )
        , view = \model -> Privacy.view model.privacy
        }
        |> ProgramTest.withSimulatedEffects identity


{-| Mirror the real `Api.deleteAccount` Cmd: only issue the DELETE effect when
the update actually transitioned into `Loading` (the single-flight/exact-match
guard passed), not merely because the click message was dispatched.
-}
effectFor : Privacy.Msg -> Privacy.Model -> Privacy.Model -> SimulatedEffect Privacy.Msg
effectFor msg before after =
    case msg of
        UserClicksDeleteAccount ->
            if isLoading after.deleting && not (isLoading before.deleting) then
                TestHelpers.authedRequestFromSpec Api.deleteAccountRequest
                    token
                    (SimulatedEffect.Http.expectWhatever GotDeleteResponse)

            else
                SimulatedEffect.Cmd.none

        _ ->
            SimulatedEffect.Cmd.none


isLoading : RemoteData Http.Error () -> Bool
isLoading remoteData =
    case remoteData of
        Loading ->
            True

        _ ->
            False


{-| Selectors for the destructive submit button ("Delete My Data" in its
enabled/disabled steady state), used to assert its enabled/disabled state.
-}
deleteSubmit : List Selector.Selector
deleteSubmit =
    [ Selector.tag "button"
    , Selector.containing [ Selector.text "Delete My Data" ]
    ]


revealed : ProgramTest.ProgramTest Model Privacy.Msg (SimulatedEffect Privacy.Msg)
revealed =
    start |> ProgramTest.clickButton "Delete My Data"


{-| Reveal the confirm block, type an exact "DELETE", and submit — leaving a
single DELETE request in flight (Loading).
-}
submitted : ProgramTest.ProgramTest Model Privacy.Msg (SimulatedEffect Privacy.Msg)
submitted =
    revealed
        |> ProgramTest.update (UserTypesDeleteConfirmation "DELETE")
        |> ProgramTest.clickButton "Delete My Data"


showsDeleteEntryPoint : Test
showsDeleteEntryPoint =
    test "entry_point: the Delete My Data action is offered before any click" <|
        \() ->
            start
                |> ProgramTest.expectViewHas
                    [ Selector.text "Delete My Data" ]


revealsConfirmationOnClick : Test
revealsConfirmationOnClick =
    test "reveal: clicking Delete My Data reveals the type-to-confirm dialog, submit disabled" <|
        \() ->
            revealed
                |> ProgramTest.expectViewHas (Selector.disabled True :: deleteSubmit)


showsDisabledCueBeforeConfirm : Test
showsDisabledCueBeforeConfirm =
    test "disabled_cue: before confirming, the submit carries btn--disabled and a hint is shown" <|
        \() ->
            revealed
                |> ProgramTest.ensureViewHas
                    [ Selector.tag "button"
                    , Selector.class "btn--disabled"
                    , Selector.containing [ Selector.text "Delete My Data" ]
                    ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Enter DELETE above to enable this button." ]


guardDisabledForLowercase : Test
guardDisabledForLowercase =
    test "guard: lowercase 'delete' keeps the submit button disabled" <|
        \() ->
            revealed
                |> ProgramTest.update (UserTypesDeleteConfirmation "delete")
                |> ProgramTest.expectViewHas (Selector.disabled True :: deleteSubmit)


guardDisabledForTruncated : Test
guardDisabledForTruncated =
    test "guard: partial 'DELET' keeps the submit button disabled" <|
        \() ->
            revealed
                |> ProgramTest.update (UserTypesDeleteConfirmation "DELET")
                |> ProgramTest.expectViewHas (Selector.disabled True :: deleteSubmit)


guardDisabledForTrailingSpace : Test
guardDisabledForTrailingSpace =
    test "guard: trailing space 'DELETE ' keeps the submit button disabled" <|
        \() ->
            revealed
                |> ProgramTest.update (UserTypesDeleteConfirmation "DELETE ")
                |> ProgramTest.expectViewHas (Selector.disabled True :: deleteSubmit)


guardEnabledForExactMatch : Test
guardEnabledForExactMatch =
    test "guard: exactly 'DELETE' enables the submit button" <|
        \() ->
            revealed
                |> ProgramTest.update (UserTypesDeleteConfirmation "DELETE")
                |> ProgramTest.expectViewHasNot (Selector.disabled True :: deleteSubmit)


showsLoadingOnSubmit : Test
showsLoadingOnSubmit =
    test "loading_state: submitting shows the queuing message" <|
        \() ->
            submitted
                |> ProgramTest.expectViewHas
                    [ Selector.text "Queuing account deletion…" ]


locksInputWhileLoading : Test
locksInputWhileLoading =
    test "single_flight_view: the confirmation input is disabled while the request is in flight" <|
        \() ->
            submitted
                |> ProgramTest.expectViewHas
                    [ Selector.tag "input"
                    , Selector.disabled True
                    ]


singleFlightBlocksSecondRequest : Test
singleFlightBlocksSecondRequest =
    test "single_flight: editing the field and re-clicking mid-flight fires no second DELETE" <|
        \() ->
            submitted
                |> ProgramTest.update (UserTypesDeleteConfirmation "DELETE")
                |> ProgramTest.update UserClicksDeleteAccount
                |> ProgramTest.expectHttpRequests "DELETE"
                    "/api/gdpr/account"
                    (\requests -> Expect.equal (List.length requests) 1)


showsQueuedOnSuccess : Test
showsQueuedOnSuccess =
    test "success_state: a 202 response confirms the deletion was queued" <|
        \() ->
            submitted
                |> ProgramTest.simulateHttpOk "DELETE"
                    "/api/gdpr/account"
                    ""
                |> ProgramTest.expectViewHas
                    [ Selector.text "Account deletion has been queued" ]


emitsAccountDeletedOnSuccess : Test
emitsAccountDeletedOnSuccess =
    test "farewell_outmsg: a successful deletion emits the AccountDeleted OutMsg" <|
        \() ->
            submitted
                |> ProgramTest.simulateHttpOk "DELETE"
                    "/api/gdpr/account"
                    ""
                |> ProgramTest.expectModel
                    (\model ->
                        if List.member Privacy.AccountDeleted model.outMsgs then
                            Expect.pass

                        else
                            Expect.fail "expected AccountDeleted OutMsg to be emitted on success"
                    )


showsErrorOnFailure : Test
showsErrorOnFailure =
    test "error_state: an HTTP failure surfaces an error message" <|
        \() ->
            submitted
                |> ProgramTest.simulateHttpResponse "DELETE"
                    "/api/gdpr/account"
                    Http.NetworkError_
                |> ProgramTest.expectViewHas
                    [ Selector.text "We couldn't queue your account deletion. Please try again." ]


cancelResetsTheFlow : Test
cancelResetsTheFlow =
    test "cancel: cancelling returns to the entry point and discards the typed text" <|
        \() ->
            revealed
                |> ProgramTest.update (UserTypesDeleteConfirmation "DELETE")
                |> ProgramTest.update UserCancelsDelete
                |> ProgramTest.ensureViewHasNot
                    [ Selector.text "Type DELETE to confirm" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Delete My Data" ]
