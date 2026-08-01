module Page.ResetPasswordTest exposing (suite)

import Expect
import Html.Attributes
import Http
import Main
import Navigation.Route as Route
import Page.ResetPassword as ResetPassword exposing (Msg(..), OutMsg(..))
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.RemoteData exposing (RemoteData(..))


update : Msg -> ResetPassword.Model -> ResetPassword.Model
update msg model =
    let
        ( newModel, _, _ ) =
            ResetPassword.update msg model
    in
    newModel


outMsgOf : Msg -> ResetPassword.Model -> OutMsg
outMsgOf msg model =
    let
        ( _, _, out ) =
            ResetPassword.update msg model
    in
    out


{-| A model with a valid, matching 8+ char password ready to submit.
-}
validModel : ResetPassword.Model
validModel =
    ResetPassword.init "tok-123"
        |> update (SetPassword "new-password")
        |> update (SetConfirmPassword "new-password")


{-| The state a reader is in the instant their reset succeeds.
-}
succeeded : ResetPassword.Model
succeeded =
    validModel
        |> update Submit
        |> update (Completed (Ok ()))


suite : Test
suite =
    describe "Page.ResetPassword"
        [ describe "submitting"
            [ test "init carries the token from the URL" <|
                \_ ->
                    (ResetPassword.init "tok-123").token |> Expect.equal "tok-123"
            , test "submitting a valid, matching password moves to Loading" <|
                \_ ->
                    validModel
                        |> update Submit
                        |> .submitting
                        |> Expect.equal Loading
            , test "a too-short password blocks submit (stays NotAsked)" <|
                \_ ->
                    ResetPassword.init "tok-123"
                        |> update (SetPassword "short")
                        |> update (SetConfirmPassword "short")
                        |> update Submit
                        |> .submitting
                        |> Expect.equal NotAsked
            , test "a mismatched confirmation blocks submit (stays NotAsked)" <|
                \_ ->
                    ResetPassword.init "tok-123"
                        |> update (SetPassword "new-password")
                        |> update (SetConfirmPassword "different-one")
                        |> update Submit
                        |> .submitting
                        |> Expect.equal NotAsked
            , test "a successful reset shows success" <|
                \_ ->
                    succeeded.submitting |> Expect.equal (Success ())
            , test "an expired/invalid token (400) shows failure" <|
                \_ ->
                    validModel
                        |> update Submit
                        |> update (Completed (Err (Http.BadStatus 400)))
                        |> .submitting
                        |> Expect.equal (Failure (Http.BadStatus 400))
            ]
        , describe "a success cannot be taken back"
            [ test "typing in the password field does not undo a success" <|
                \_ ->
                    succeeded
                        |> update (SetPassword "having-second-thoughts")
                        |> .submitting
                        |> Expect.equal (Success ())
            , test "typing in the confirm field does not undo a success" <|
                \_ ->
                    succeeded
                        |> update (SetConfirmPassword "having-second-thoughts")
                        |> .submitting
                        |> Expect.equal (Success ())
            , test "a late failure response cannot overwrite a success" <|
                \_ ->
                    -- The exact sequence the double-submit produced: 200 first,
                    -- then a 400 for the now-burned single-use token.
                    succeeded
                        |> update (Completed (Err (Http.BadStatus 400)))
                        |> .submitting
                        |> Expect.equal (Success ())
            , test "the success view survives a keystroke — the reader still sees the confirmation" <|
                \_ ->
                    succeeded
                        |> update (SetPassword "having-second-thoughts")
                        |> ResetPassword.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Your password has been reset. Taking you to sign in…" ]
            , test "positive control — the confirmation is genuinely absent before a success" <|
                \_ ->
                    -- Pairs with the assertion above: without this, "the copy is
                    -- present" could pass against a view that always shows it.
                    validModel
                        |> ResetPassword.view
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.text "Your password has been reset. Taking you to sign in…" ]
            ]
        , describe "typing clears a stale error, and only that"
            [ test "typing clears a failure so the reader can retry" <|
                \_ ->
                    validModel
                        |> update Submit
                        |> update (Completed (Err (Http.BadStatus 400)))
                        |> update (SetPassword "another-try")
                        |> .submitting
                        |> Expect.equal NotAsked
            , test "typing mid-flight does NOT re-arm the submit button" <|
                \_ ->
                    -- The defect: `submitting = NotAsked` on every keystroke put
                    -- an in-flight request back into a submittable state, so a
                    -- second press burned the single-use token behind a reset
                    -- that had already worked.
                    validModel
                        |> update Submit
                        |> update (SetConfirmPassword "new-password!")
                        |> .submitting
                        |> Expect.equal Loading
            , test "a second Submit while one is in flight is ignored" <|
                \_ ->
                    validModel
                        |> update Submit
                        |> update Submit
                        |> .submitting
                        |> Expect.equal Loading
            , test "a Submit after success is ignored" <|
                \_ ->
                    succeeded
                        |> update Submit
                        |> .submitting
                        |> Expect.equal (Success ())
            ]
        , describe "auto-advance to sign in"
            [ test "a success asks Main to advance" <|
                \_ ->
                    outMsgOf AdvanceToSignIn succeeded
                        |> Expect.equal AdvanceToLogin
            , test "the advance timer is inert if the page is not in a success state" <|
                \_ ->
                    outMsgOf AdvanceToSignIn validModel
                        |> Expect.equal NoOut
            , test "nothing else raises an OutMsg" <|
                \_ ->
                    [ outMsgOf (SetPassword "x") validModel
                    , outMsgOf (SetConfirmPassword "x") validModel
                    , outMsgOf Submit validModel
                    , outMsgOf (Completed (Ok ())) validModel
                    , outMsgOf (Completed (Err Http.NetworkError)) validModel
                    ]
                        |> Expect.equalLists [ NoOut, NoOut, NoOut, NoOut, NoOut ]
            , test "THE WIRE — Main sends AdvanceToLogin to the sign-in page" <|
                \_ ->
                    -- ⛔ `Main.update`'s ResetPasswordMsg branch calls
                    -- `Main.resetPasswordDestination` rather than deciding the
                    -- destination inline, so this test covers the code that
                    -- ships. `Main.Model` embeds an unconstructable `Nav.Key`,
                    -- which is exactly how a wire like this ends up with two
                    -- correct ends and an untested join.
                    Main.resetPasswordDestination AdvanceToLogin
                        |> Expect.equal (Just Route.Login)
            , test "THE WIRE — NoOut navigates nowhere" <|
                \_ ->
                    Main.resetPasswordDestination NoOut
                        |> Expect.equal Nothing
            , test "the confirmation stays on screen long enough to read" <|
                \_ ->
                    ResetPassword.advanceDelayMs
                        |> Expect.atLeast 1000
            ]
        , describe "the confirmation is announced, not just drawn"
            [ test "the success message is a live region" <|
                \_ ->
                    succeeded
                        |> ResetPassword.view
                        |> Query.fromHtml
                        |> Query.has
                            [ Selector.attribute (Html.Attributes.attribute "role" "status")
                            , Selector.text "Your password has been reset. Taking you to sign in…"
                            ]
            , test "the reader can still go now rather than wait" <|
                \_ ->
                    succeeded
                        |> ResetPassword.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Sign in" ]
            ]
        ]
