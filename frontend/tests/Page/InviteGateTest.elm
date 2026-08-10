module Page.InviteGateTest exposing (suite)

{-| US-14.1.3 — the closed-beta gate on the Register tab.

Every negative is paired with its positive control (the same selector under
the opposite gate state), so a renamed class or test id cannot green these
vacuously. The fail-CLOSED property lives in `Main.decodeConfig` and is pinned
here too: a malformed or absent `inviteOnly` must read as `True`.

-}

import Expect
import Html
import Html.Attributes
import Http
import Json.Encode as Encode
import Main
import Page.Login as Login
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.RemoteData exposing (RemoteData(..))


{-| A card on the Register tab, gate applied per the flag.
-}
registerCard : Bool -> Login.Model
registerCard inviteOnly =
    Login.init Login.Fresh
        |> Login.withInviteOnly inviteOnly
        |> (\model -> { model | mode = Login.RegisterMode })


rendered : Login.Model -> Query.Single Login.Msg
rendered model =
    Login.view model |> Query.fromHtml


suite : Test
suite =
    describe "invite-only registration gate (US-14.1.3)"
        [ describe "the uninvited path"
            [ test "gate on: the Register tab shows the panel, not the form" <|
                \_ ->
                    rendered (registerCard True)
                        |> Expect.all
                            [ Query.has [ Selector.attribute (attr "data-testid" "invite-only-panel") ]
                            , Query.hasNot [ Selector.id "display-name" ]
                            , Query.hasNot [ Selector.id "email" ]
                            ]
            , test "gate off: the same selectors flip — form present, panel absent (positive control)" <|
                \_ ->
                    rendered (registerCard False)
                        |> Expect.all
                            [ Query.hasNot [ Selector.attribute (attr "data-testid" "invite-only-panel") ]
                            , Query.has [ Selector.id "display-name" ]
                            , Query.has [ Selector.id "email" ]
                            ]
            , test "the tabs stay visible while the gate is locked — hiding the tab would lie" <|
                \_ ->
                    rendered (registerCard True)
                        |> Query.has [ Selector.text "Register" ]
            ]
        , describe "redeeming"
            [ test "an accepted code reveals the form with the code held read-only" <|
                \_ ->
                    let
                        unlocked =
                            registerCard True
                                |> (\model ->
                                        { model
                                            | inviteCode = "STK-4F2A-9C1D"
                                            , inviteCheck =
                                                Success { expiresAt = Nothing, emailBound = False }
                                        }
                                   )
                    in
                    rendered unlocked
                        |> Expect.all
                            [ Query.hasNot [ Selector.attribute (attr "data-testid" "invite-only-panel") ]
                            , Query.has [ Selector.id "display-name" ]
                            , Query.has
                                [ Selector.attribute (attr "data-testid" "invite-code-input")
                                , Selector.attribute (attr "readonly" "readonly")
                                ]
                            , Query.has [ Selector.text "Invitation accepted. Welcome — the door is open." ]
                            ]
            , test "a refusal names its reason: unknown code" <|
                \_ ->
                    rendered (refused 404)
                        |> Query.has [ Selector.text "We don't recognise that code. Check it against the message you were sent." ]
            , test "revoked reads exactly as expired — the reader learns nothing extra" <|
                \_ ->
                    rendered (refused 403)
                        |> Query.has
                            [ Selector.text "That invitation has expired. Ask whoever sent it for a fresh one." ]
            , test "an exhausted code says it has been used" <|
                \_ ->
                    rendered (refused 409)
                        |> Query.has [ Selector.text "That invitation has already been used." ]
            , test "typing again clears a refusal — the old code's failure must not gate the new one" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Login.update (Login.InviteCodeChanged "STK-NEW") (refused 404)
                    in
                    Expect.equal model.inviteCheck NotAsked
            ]
        , describe "decodeConfig fails CLOSED"
            [ test "an absent inviteOnly field means the gate is ON" <|
                \_ ->
                    Main.decodeConfig (Encode.object [ ( "ageGatingEnabled", Encode.bool False ) ])
                        |> .inviteOnly
                        |> Expect.equal True
            , test "a malformed inviteOnly means the gate is ON" <|
                \_ ->
                    Main.decodeConfig
                        (Encode.object [ ( "inviteOnly", Encode.string "yes" ) ])
                        |> .inviteOnly
                        |> Expect.equal True
            , test "an explicit false opens registration — the positive control" <|
                \_ ->
                    Main.decodeConfig (Encode.object [ ( "inviteOnly", Encode.bool False ) ])
                        |> .inviteOnly
                        |> Expect.equal False
            ]
        ]


refused : Int -> Login.Model
refused status =
    registerCard True
        |> (\model ->
                { model
                    | inviteCode = "STK-BAD"
                    , inviteCheck = Failure (Http.BadStatus status)
                }
           )


attr : String -> String -> Html.Attribute msg
attr =
    Html.Attributes.attribute
