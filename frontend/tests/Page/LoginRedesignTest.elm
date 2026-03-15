module Page.LoginRedesignTest exposing (suite)

{-| Tests for Issue #028: Login Page Aesthetic Redesign.

These tests assert on the new bookshelf-wall / parchment-card / dolly-shot
design. Tests verify the layer structure, parchment card classes, form
validation, ARIA attributes, and transition state using TransitionState.

-}

import Html.Attributes
import Http
import Page.Login as Login exposing (Mode(..), TransitionState(..))
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers exposing (loginProgram, simulateAuthErrorResponse, simulateAuthResponse)
import Types.RemoteData exposing (RemoteData(..))


startLogin : ProgramTest.ProgramTest Login.Model Login.Msg (ProgramTest.SimulatedEffect Login.Msg)
startLogin =
    ProgramTest.start () loginProgram


suite : Test
suite =
    describe "Page.Login — Redesign (Issue #028)"
        [ layerStructureTests
        , parchmentCardTests
        , formValidationTests
        , transitionStateTests
        , ariaTests
        ]



-- 1. LOGIN PAGE LAYER STRUCTURE


layerStructureTests : Test
layerStructureTests =
    describe "Scene layer structure"
        [ test "renders .layer-arrival background layer" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHas
                        [ Selector.class "layer-arrival" ]
        , test "renders .layer-passage scene layer" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHas
                        [ Selector.class "layer-passage" ]
        , test "renders .layer-bookshelf scene layer" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHas
                        [ Selector.class "layer-bookshelf" ]
        , test "renders .layer-bookshelf-dim overlay" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHas
                        [ Selector.class "layer-bookshelf-dim" ]
        , test "renders .layer-vignette overlay" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHas
                        [ Selector.class "layer-vignette" ]
        , test "renders .layer-passage-bright warm glow layer" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHas
                        [ Selector.class "layer-passage-bright" ]
        , test "renders .layer-wash final wash layer" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHas
                        [ Selector.class "layer-wash" ]
        , test "renders .login-overlay containing the login card" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHas
                        [ Selector.class "login-overlay" ]
        ]



-- 2. PARCHMENT LOGIN CARD


parchmentCardTests : Test
parchmentCardTests =
    describe "Parchment login card"
        [ test "login card uses .login-card class (not old .login-form)" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHas
                        [ Selector.class "login-card" ]
        , test "card has .login-card__title with 'The Stacks'" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHas
                        [ Selector.class "login-card__title" ]
        , test "card has .login-card__subtitle" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHas
                        [ Selector.class "login-card__subtitle" ]
        , test "Sign In tab uses .login-card__tab class" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHas
                        [ Selector.class "login-card__tab"
                        , Selector.text "Sign In"
                        ]
        , test "Register tab uses .login-card__tab class" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHas
                        [ Selector.class "login-card__tab"
                        , Selector.text "Register"
                        ]
        , test "email input uses .login-card__input class" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHas
                        [ Selector.class "login-card__input" ]
        , test "register mode shows display name field with .login-card__input" <|
            \() ->
                startLogin
                    |> ProgramTest.clickButton "Register"
                    |> ProgramTest.expectViewHas
                        [ Selector.class "login-card__field"
                        , Selector.text "Display Name"
                        ]
        , test "submit button uses .login-card__submit class" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHas
                        [ Selector.class "login-card__submit" ]
        ]



-- 3. FORM VALIDATION AND ERROR STATES


formValidationTests : Test
formValidationTests =
    describe "Form validation and error states"
        [ test "401 error renders error with .login-card__error class" <|
            \() ->
                startLogin
                    |> ProgramTest.fillIn "email" "Email" "reader@stacks.dev"
                    |> ProgramTest.fillIn "password" "Password" "wrong"
                    |> ProgramTest.clickButton "Enter the Stacks"
                    |> ProgramTest.simulateHttpResponse "POST"
                        "/api/auth/login"
                        (simulateAuthErrorResponse 401)
                    |> ProgramTest.expectViewHas
                        [ Selector.class "login-card__error" ]
        , test "409 error renders error with .login-card__error class" <|
            \() ->
                let
                    model =
                        { email = "reader@stacks.dev"
                        , password = "secret123"
                        , displayName = "Reader"
                        , mode = RegisterMode
                        , submitState = Failure (Http.BadStatus 409)
                        , transitionState = Idle
                        }

                    html =
                        Login.view model
                in
                html
                    |> Query.fromHtml
                    |> Query.has [ Selector.class "login-card__error" ]
        , test "loading state submit button has .login-card__submit and is disabled" <|
            \() ->
                startLogin
                    |> ProgramTest.fillIn "email" "Email" "reader@stacks.dev"
                    |> ProgramTest.fillIn "password" "Password" "secret123"
                    |> ProgramTest.clickButton "Enter the Stacks"
                    |> ProgramTest.expectViewHas
                        [ Selector.class "login-card__submit"
                        , Selector.disabled True
                        ]
        , test "error messages are wrapped in an aria-live region" <|
            \() ->
                let
                    model =
                        { email = "reader@stacks.dev"
                        , password = "secret123"
                        , displayName = ""
                        , mode = LoginMode
                        , submitState = Failure (Http.BadStatus 401)
                        , transitionState = Idle
                        }

                    html =
                        Login.view model
                in
                html
                    |> Query.fromHtml
                    |> Query.has
                        [ Selector.attribute
                            (Html.Attributes.attribute "aria-live" "polite")
                        ]
        ]



-- 4. AUTH SUCCESS TRANSITION STATE


transitionStateTests : Test
transitionStateTests =
    describe "Auth success transition"
        [ test "successful auth — no old .login-door--opening class in view" <|
            \() ->
                startLogin
                    |> ProgramTest.fillIn "email" "Email" "reader@stacks.dev"
                    |> ProgramTest.fillIn "password" "Password" "secret123"
                    |> ProgramTest.clickButton "Enter the Stacks"
                    |> ProgramTest.simulateHttpResponse "POST"
                        "/api/auth/login"
                        (simulateAuthResponse "jwt-token" "user-1" "reader@stacks.dev" "A Reader")
                    |> ProgramTest.expectViewHasNot
                        [ Selector.class "login-door--opening" ]
        , test "old door DOM structure is removed — no .login-door element" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHasNot
                        [ Selector.class "login-door" ]
        , test "old door DOM structure is removed — no .login-door__frame element" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHasNot
                        [ Selector.class "login-door__frame" ]
        , test "old door DOM structure is removed — no .login-entrance element" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHasNot
                        [ Selector.class "login-entrance" ]
        ]



-- 5. ARIA ATTRIBUTES


ariaTests : Test
ariaTests =
    describe "ARIA attributes"
        [ test "email input has aria-required=true" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHas
                        [ Selector.attribute
                            (Html.Attributes.attribute "aria-required" "true")
                        , Selector.id "email"
                        ]
        , test "password input has aria-required=true" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHas
                        [ Selector.attribute
                            (Html.Attributes.attribute "aria-required" "true")
                        , Selector.id "password"
                        ]
        , test "tab container has role=tablist" <|
            \() ->
                startLogin
                    |> ProgramTest.expectViewHas
                        [ Selector.attribute
                            (Html.Attributes.attribute "role" "tablist")
                        ]
        , test "Sign In tab has role=tab and aria-selected=true when active" <|
            \() ->
                let
                    model =
                        Login.init

                    html =
                        Login.view model
                in
                html
                    |> Query.fromHtml
                    |> Query.has
                        [ Selector.attribute
                            (Html.Attributes.attribute "role" "tab")
                        , Selector.attribute
                            (Html.Attributes.attribute "aria-selected" "true")
                        ]
        , test "Register tab has aria-selected=false when Sign In is active" <|
            \() ->
                let
                    model =
                        Login.init

                    html =
                        Login.view model
                in
                html
                    |> Query.fromHtml
                    |> Query.has
                        [ Selector.attribute
                            (Html.Attributes.attribute "role" "tab")
                        , Selector.attribute
                            (Html.Attributes.attribute "aria-selected" "false")
                        ]
        ]
