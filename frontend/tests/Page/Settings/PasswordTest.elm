module Page.Settings.PasswordTest exposing (suite)

{-| #126 punch 18/19 — the Settings → Password change form.

Drives `Page.Settings.Password.update`/`view` through the change lifecycle:
`init` is empty and idle; the three setters update their fields and clear any
prior save state; `SavePassword` blocks (no dispatch, inline error) for each
validation branch — short, mismatched, empty current password — and dispatches
only for valid input with a token; a successful completion clears every field;
and a 422 renders the wrong-current-password copy.

-}

import Expect
import Http
import Page.Settings.Password as Password exposing (Msg(..))
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.RemoteData exposing (RemoteData(..))


{-| The model out of the page's `( Model, Cmd Msg, OutMsg )` triple. The page
gained an `OutMsg` in #361 so a mid-form 401 can reach the global session-expiry
interceptor; the `OutMsg` itself is asserted in `Page.SessionExpiryPagesTest`.
-}
modelOf : ( Password.Model, Cmd Msg, Password.OutMsg ) -> Password.Model
modelOf ( model, _, _ ) =
    model


{-| Apply one message with a token present (the save-dispatch path only fires
with a token; the non-dispatch branches ignore it).
-}
applyWithToken : Msg -> Password.Model -> Password.Model
applyWithToken msg model =
    Password.update msg model (Just "test-token") |> modelOf


{-| A model with valid, matching input ready to save.
-}
validInput : Password.Model
validInput =
    Password.init
        |> applyWithToken (SetCurrentPassword "old-password")
        |> applyWithToken (SetNewPassword "new-password-123")
        |> applyWithToken (SetConfirmPassword "new-password-123")


suite : Test
suite =
    describe "Page.Settings.Password (#126 punch 18/19)"
        [ describe "init"
            [ test "starts with every field empty and saving NotAsked" <|
                \_ ->
                    Expect.all
                        [ \m -> m.currentPassword |> Expect.equal ""
                        , \m -> m.newPassword |> Expect.equal ""
                        , \m -> m.confirmPassword |> Expect.equal ""
                        , \m -> m.saving |> Expect.equal NotAsked
                        ]
                        Password.init
            ]
        , describe "setters"
            [ test "SetCurrentPassword updates the field" <|
                \_ ->
                    Password.init
                        |> applyWithToken (SetCurrentPassword "secret")
                        |> .currentPassword
                        |> Expect.equal "secret"
            , test "SetNewPassword updates the field" <|
                \_ ->
                    Password.init
                        |> applyWithToken (SetNewPassword "brand-new")
                        |> .newPassword
                        |> Expect.equal "brand-new"
            , test "SetConfirmPassword updates the field" <|
                \_ ->
                    Password.init
                        |> applyWithToken (SetConfirmPassword "brand-new")
                        |> .confirmPassword
                        |> Expect.equal "brand-new"
            , test "a setter clears a prior save result back to NotAsked" <|
                \_ ->
                    -- A completed (or failed) save must not linger while the user
                    -- retypes; editing any field resets the banner.
                    validInput
                        |> applyWithToken (SaveCompleted (Ok ()))
                        |> applyWithToken (SetNewPassword "typing-again")
                        |> .saving
                        |> Expect.equal NotAsked
            ]
        , describe "validation blocks the save (no dispatch)"
            [ test "a new password under 8 characters renders the length error and stays idle" <|
                \_ ->
                    let
                        blocked =
                            Password.init
                                |> applyWithToken (SetCurrentPassword "old-password")
                                |> applyWithToken (SetNewPassword "short")
                                |> applyWithToken (SetConfirmPassword "short")
                                |> applyWithToken SavePassword
                    in
                    Expect.all
                        [ \m -> m.saving |> Expect.equal NotAsked
                        , \m ->
                            Password.view m
                                |> Query.fromHtml
                                |> Query.has [ Selector.text "New password must be at least 8 characters." ]
                        ]
                        blocked
            , test "a mismatched confirmation renders the mismatch error and stays idle" <|
                \_ ->
                    let
                        blocked =
                            Password.init
                                |> applyWithToken (SetCurrentPassword "old-password")
                                |> applyWithToken (SetNewPassword "new-password-123")
                                |> applyWithToken (SetConfirmPassword "different-123")
                                |> applyWithToken SavePassword
                    in
                    Expect.all
                        [ \m -> m.saving |> Expect.equal NotAsked
                        , \m ->
                            Password.view m
                                |> Query.fromHtml
                                |> Query.has [ Selector.text "New password and confirmation do not match." ]
                        ]
                        blocked
            , test "an empty current password renders its error and stays idle" <|
                \_ ->
                    let
                        blocked =
                            Password.init
                                |> applyWithToken (SetNewPassword "new-password-123")
                                |> applyWithToken (SetConfirmPassword "new-password-123")
                                |> applyWithToken SavePassword
                    in
                    Expect.all
                        [ \m -> m.saving |> Expect.equal NotAsked
                        , \m ->
                            Password.view m
                                |> Query.fromHtml
                                |> Query.has [ Selector.text "Please enter your current password." ]
                        ]
                        blocked
            ]
        , describe "valid input dispatches the save"
            [ test "valid input with a token transitions to Loading" <|
                \_ ->
                    validInput
                        |> applyWithToken SavePassword
                        |> .saving
                        |> Expect.equal Loading
            , test "valid input without a token is a no-op (no dispatch)" <|
                \_ ->
                    Password.update SavePassword validInput Nothing
                        |> modelOf
                        |> .saving
                        |> Expect.equal NotAsked
            ]
        , describe "completion"
            [ test "a successful completion clears every field and reports success" <|
                \_ ->
                    let
                        completed =
                            validInput
                                |> applyWithToken SavePassword
                                |> applyWithToken (SaveCompleted (Ok ()))
                    in
                    Expect.all
                        [ \m -> m.currentPassword |> Expect.equal ""
                        , \m -> m.newPassword |> Expect.equal ""
                        , \m -> m.confirmPassword |> Expect.equal ""
                        , \m -> m.saving |> Expect.equal (Success ())
                        ]
                        completed
            , test "a successful completion renders the success copy" <|
                \_ ->
                    validInput
                        |> applyWithToken SavePassword
                        |> applyWithToken (SaveCompleted (Ok ()))
                        |> Password.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Password changed successfully." ]
            , test "a 422 renders the wrong-current-password copy" <|
                \_ ->
                    validInput
                        |> applyWithToken SavePassword
                        |> applyWithToken (SaveCompleted (Err (Http.BadStatus 422)))
                        |> Password.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Current password is incorrect." ]
            , test "a non-422 failure renders the generic error copy" <|
                \_ ->
                    validInput
                        |> applyWithToken SavePassword
                        |> applyWithToken (SaveCompleted (Err Http.NetworkError))
                        |> Password.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Could not change password. Please try again." ]
            ]
        ]
