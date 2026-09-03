module AdminSessionEndTest exposing (suite)

{-| An operator whose admin session ends is told so.

There are two ways it ends — the operator ends it deliberately from the admin
chrome, or an admin call comes back 401 mid-action — and they were built as two
separate pieces of code. The deliberate one passed a notice; the expiry one
passed a bare `AdminSession.init`. So an operator who chose to sign out got an
explanation, and an operator who was signed out mid-action got a bare login form
with no account of what had happened, on a product where the admin session and
the ordinary session are different things and "signed out" is ambiguous.

`Main.handleAdminSessionExpiry`'s own docstring said it sent them "to the admin
login with a notice". It did not.

-}

import Expect
import Main
import Navigation.Route as Route
import Page.Admin.Session as AdminSession
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector


{-| The admin-gate model an operator lands on once their session is over.
-}
gateAfterEnding : Maybe AdminSession.Model
gateAfterEnding =
    case Main.adminGateAfterEnding Route.AdminInvites of
        Main.PageAdminGate _ session ->
            Just session

        _ ->
            Nothing


suite : Test
suite =
    describe "ending an admin session"
        [ test "puts the operator back on the admin gate" <|
            \() ->
                gateAfterEnding
                    |> (/=) Nothing
                    |> Expect.equal True
        , test "tells them what happened, rather than presenting a bare form" <|
            \() ->
                case gateAfterEnding of
                    Just session ->
                        AdminSession.view session
                            |> Query.fromHtml
                            |> Query.has [ Selector.text "admin session has ended" ]

                    Nothing ->
                        Expect.fail "expected the admin gate"
        , test "says the ordinary session survives, because the two are different things" <|
            \() ->
                case gateAfterEnding of
                    Just session ->
                        AdminSession.view session
                            |> Query.fromHtml
                            |> Query.has [ Selector.text "ordinary session is untouched" ]

                    Nothing ->
                        Expect.fail "expected the admin gate"
        ]
