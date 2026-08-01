module PasswordRuleTest exposing (suite)

{-| One rule, one sentence — asserted where the reader actually meets it.

The failure this guards against is not "the rule is wrong". It is "the rule is
stated in four places and two of them disagree", which no ordinary test notices
because each page's own test asserts its own copy and passes.

⚠️ Every negative assertion here is paired with a positive control on the same
view. `scripts/check-prose-assertions.sh` cannot see `ensureViewHasNot` /
`hasNot`, so an unpaired "the old wording is gone" would also pass against a view
that renders nothing at all.

-}

import Expect
import Http
import Page.Login as Login
import Page.ResetPassword as ResetPassword
import Page.Settings.Password as SettingsPassword
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.PasswordRule as PasswordRule


{-| The reset page with a too-short password typed in, so its inline validation
error is on screen.
-}
resetWithShortPassword : ResetPassword.Model
resetWithShortPassword =
    let
        step msg model =
            let
                ( newModel, _, _ ) =
                    ResetPassword.update msg model
            in
            newModel
    in
    ResetPassword.init "tok-123"
        |> step (ResetPassword.SetPassword "short")
        |> step (ResetPassword.SetConfirmPassword "short")


{-| The reset page after the server rejected the password with a 422.
-}
resetRejected : ResetPassword.Model
resetRejected =
    let
        step msg model =
            let
                ( newModel, _, _ ) =
                    ResetPassword.update msg model
            in
            newModel
    in
    ResetPassword.init "tok-123"
        |> step (ResetPassword.SetPassword "long-enough-password")
        |> step (ResetPassword.SetConfirmPassword "long-enough-password")
        |> step ResetPassword.Submit
        |> step (ResetPassword.Completed (Err (Http.BadStatus 422)))


settingsWithShortPassword : SettingsPassword.Model
settingsWithShortPassword =
    let
        step msg model =
            let
                ( newModel, _, _ ) =
                    SettingsPassword.update msg model Nothing
            in
            newModel
    in
    SettingsPassword.init
        |> step (SettingsPassword.SetNewPassword "short")
        |> step (SettingsPassword.SetConfirmPassword "short")


suite : Test
suite =
    describe "The password-length rule is stated once"
        [ describe "the source itself"
            [ test "the requirement hint names the minimum" <|
                \_ ->
                    PasswordRule.requirementHint
                        |> Expect.equal "At least 8 characters"
            , test "the failure sentence names the minimum" <|
                \_ ->
                    PasswordRule.tooShort
                        |> Expect.equal "Password must be at least 8 characters."
            , test "a subject-qualified failure keeps the same clause" <|
                \_ ->
                    PasswordRule.tooShortFor "New password"
                        |> Expect.equal "New password must be at least 8 characters."
            , test "the number in the copy is the number that is enforced" <|
                \_ ->
                    -- If `minLength` moved and the sentence did not, this fails.
                    -- That is the whole point: the copy is built from the number.
                    ( PasswordRule.isLongEnough (String.repeat (PasswordRule.minLength - 1) "a")
                    , PasswordRule.isLongEnough (String.repeat PasswordRule.minLength "a")
                    )
                        |> Expect.equal ( False, True )
            , test "the sentence contains the enforced number, not a different one" <|
                \_ ->
                    PasswordRule.tooShort
                        |> String.contains (String.fromInt PasswordRule.minLength)
                        |> Expect.equal True
            ]
        , describe "every place the reader is told the rule says the same thing"
            [ test "the register card's inline hint" <|
                \_ ->
                    Login.validatePassword "short"
                        |> Expect.equal (Login.Invalid PasswordRule.tooShort)
            , test "the register card's 422 message" <|
                \_ ->
                    Login.errorMessage Login.RegisterMode
                        (Login.SubmitValidationError
                            [ ( "password", [ "must be at least 8 characters" ] ) ]
                        )
                        |> Expect.equal PasswordRule.tooShort
            , test "the reset page's inline validation" <|
                \_ ->
                    resetWithShortPassword
                        |> ResetPassword.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.text PasswordRule.tooShort ]
            , test "the reset page's 422 message" <|
                \_ ->
                    resetRejected
                        |> ResetPassword.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.text PasswordRule.tooShort ]
            , test "the settings form's inline validation" <|
                \_ ->
                    settingsWithShortPassword
                        |> SettingsPassword.view
                        |> Query.fromHtml
                        |> Query.has
                            [ Selector.text (PasswordRule.tooShortFor "New password") ]
            ]
        , describe "the wordings that used to disagree are gone"
            [ test "the register card no longer spells the number as a word" <|
                \_ ->
                    -- Positive control FIRST, on the same value: without it,
                    -- "the old copy is absent" would pass against an empty
                    -- message. `check-prose-assertions.sh` cannot see a bare
                    -- negative, so it is paired here by hand.
                    let
                        message =
                            Login.errorMessage Login.RegisterMode
                                (Login.SubmitValidationError
                                    [ ( "password", [ "must be at least 8 characters" ] ) ]
                                )
                    in
                    ( String.contains "at least 8 characters" message
                    , String.contains "eight characters" message
                    )
                        |> Expect.equal ( True, False )
            , test "the register card's two statements of the rule are now the same string" <|
                \_ ->
                    -- They were "Password must be at least 8 characters" (the
                    -- inline hint, no full stop) and "That password is too
                    -- slight; please choose at least eight characters." (the
                    -- 422) — on the SAME form, about the same rule, with the
                    -- number written two different ways. Comparing them to each
                    -- other rather than to a literal is what makes this survive
                    -- a future rewording: the guarantee is agreement, not wording.
                    let
                        inlineHint =
                            case Login.validatePassword "short" of
                                Login.Invalid message ->
                                    message

                                _ ->
                                    "«validatePassword did not reject a 5-character password»"

                        serverMessage =
                            Login.errorMessage Login.RegisterMode
                                (Login.SubmitValidationError
                                    [ ( "password", [ "must be at least 8 characters" ] ) ]
                                )
                    in
                    inlineHint |> Expect.equal serverMessage
            ]
        , describe "the register card still speaks its own language for everything else"
            [ test "a duplicate email keeps the in-world copy" <|
                \_ ->
                    -- The collapse is scoped: only the length rule loses its
                    -- second voice, because only the length rule is ALSO stated
                    -- inline on the same card. The other branches say something
                    -- the reader is told nowhere else.
                    Login.errorMessage Login.RegisterMode
                        (Login.SubmitValidationError
                            [ ( "email", [ "has already been taken" ] ) ]
                        )
                        |> Expect.equal "A reader with that email already frequents these halls. Try signing in instead."
            , test "a missing display name keeps the in-world copy" <|
                \_ ->
                    Login.errorMessage Login.RegisterMode
                        (Login.SubmitValidationError
                            [ ( "display_name", [ "can't be blank" ] ) ]
                        )
                        |> Expect.equal "Please give a name for your reader's card."
            ]
        ]
