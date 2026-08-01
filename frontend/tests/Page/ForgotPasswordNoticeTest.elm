module Page.ForgotPasswordNoticeTest exposing (suite)

{-| The forgot-password acknowledgement (#363).

Asking for a reset link is a request whose whole outcome is a sentence: the
reader's inbox is somewhere else, and the endpoint deliberately answers the same
way whether or not the address is registered, so this line is the only evidence
anything happened.

It was rendered as `p [ class "login-card__subtitle" ]` — the same class as the
"Enter your email and we'll send you a link" helper text two elements above it,
in no live region at all. A screen-reader user pressed the button and was told
nothing; a sighted one got a line of helper text where a confirmation belonged.

Driven through the real card: switch to reset mode, type an address, press the
button, answer the request.

-}

import Dict
import Html.Attributes
import Http
import Page.Login as Login
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers exposing (loginProgram)


{-| The card in reset mode with an address typed in, one press away from asking.
-}
askingForALink : ProgramTest.ProgramTest Login.Model Login.Msg (ProgramTest.SimulatedEffect Login.Msg)
askingForALink =
    ProgramTest.start () loginProgram
        |> ProgramTest.clickButton "Forgot your password?"
        |> ProgramTest.fillIn "email" "Email" "reader@stacks.dev"
        |> ProgramTest.clickButton "Send reset link"


suite : Test
suite =
    describe "Forgot-password acknowledgement"
        [ test "a successful request is announced, not merely drawn" <|
            \() ->
                askingForALink
                    |> ProgramTest.simulateHttpOk "POST" "/api/auth/forgot-password" "{}"
                    |> ProgramTest.expectViewHas
                        [ Selector.attribute (Html.Attributes.attribute "role" "status")
                        , Selector.text "If that email is registered, a reset link is on its way. Check your inbox."
                        ]
        , test "the acknowledgement is a notice, not helper text" <|
            \() ->
                -- `login-card__subtitle` is the class of the "Enter your email
                -- and we'll send you a link" line above it. A confirmation and
                -- an instruction must not be the same thing.
                askingForALink
                    |> ProgramTest.simulateHttpOk "POST" "/api/auth/forgot-password" "{}"
                    |> ProgramTest.ensureViewHas
                        [ Selector.class "login-card__notice"
                        , Selector.text "If that email is registered, a reset link is on its way. Check your inbox."
                        ]
                    |> ProgramTest.expectViewHasNot
                        [ Selector.text "If that email is registered, a reset link is on its way. Check your inbox."
                        , Selector.class "login-card__subtitle"
                        ]
        , test "positive control — nothing is acknowledged before the request answers" <|
            \() ->
                -- Pairs with the negative above. `check-prose-assertions.sh`
                -- cannot see `expectViewHasNot`, so the control is written by
                -- hand: without it, "the copy is not helper text" would pass
                -- against a card that never shows the copy at all.
                ProgramTest.start () loginProgram
                    |> ProgramTest.clickButton "Forgot your password?"
                    |> ProgramTest.expectViewHasNot
                        [ Selector.text "If that email is registered, a reset link is on its way. Check your inbox." ]
        , test "a failed request is announced too" <|
            \() ->
                askingForALink
                    |> ProgramTest.simulateHttpResponse "POST"
                        "/api/auth/forgot-password"
                        (Http.BadStatus_
                            { url = "/api/auth/forgot-password"
                            , statusCode = 500
                            , statusText = "Internal Server Error"
                            , headers = Dict.empty
                            }
                            ""
                        )
                    |> ProgramTest.expectViewHas
                        [ Selector.attribute (Html.Attributes.attribute "role" "status")
                        , Selector.class "login-card__error"
                        , Selector.text "Something went wrong. Please try again."
                        ]
        ]
