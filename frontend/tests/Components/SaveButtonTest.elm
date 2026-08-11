module Components.SaveButtonTest exposing (suite)

{-| The save button that six modules used to write out by hand.

The interesting tests here are the ones about the `Success` branch. Every copy
rendered it as a bare `button [ class "btn btn--primary" ] [ text "Saved!" ]` —
enabled, focusable, keyboard-activatable, and wired to nothing. A test asserting
"the button says Saved!" passed against that button, which is why six copies of
it shipped.

-}

import Components.SaveButton as SaveButton
import Expect
import Html.Attributes
import Http
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.RemoteData exposing (RemoteData(..))


type Msg
    = Save


button : RemoteData Http.Error () -> Query.Single Msg
button state =
    SaveButton.primary state Save "Save Profile" |> Query.fromHtml


suite : Test
suite =
    describe "Components.SaveButton"
        [ describe "labels"
            [ test "idle shows the action label" <|
                \_ ->
                    button NotAsked |> Query.has [ Selector.text "Save Profile" ]
            , test "in flight shows the busy label" <|
                \_ ->
                    button Loading |> Query.has [ Selector.text "Saving…" ]
            , test "saved shows the past-tense label" <|
                \_ ->
                    button (Success ()) |> Query.has [ Selector.text "Saved!" ]
            , test "a failure returns to the action label so the reader can retry" <|
                \_ ->
                    button (Failure Http.NetworkError)
                        |> Query.has [ Selector.text "Save Profile" ]
            ]
        , describe "the Success branch is not a dead end"
            [ test "a saved button still fires its save message when clicked" <|
                \_ ->
                    button (Success ())
                        |> Event.simulate Event.click
                        |> Event.expect Save
            , test "a saved button is not disabled" <|
                \_ ->
                    button (Success ())
                        |> Query.hasNot
                            [ Selector.attribute (Html.Attributes.disabled True) ]
            , test "an idle button fires its save message" <|
                \_ ->
                    button NotAsked
                        |> Event.simulate Event.click
                        |> Event.expect Save
            , test "a failed button fires its save message (retry)" <|
                \_ ->
                    button (Failure Http.NetworkError)
                        |> Event.simulate Event.click
                        |> Event.expect Save
            ]
        , describe "the Loading branch really is disabled"
            [ test "an in-flight button carries the disabled attribute, not just the class" <|
                \_ ->
                    button Loading
                        |> Query.has
                            [ Selector.attribute (Html.Attributes.disabled True)
                            , Selector.class "btn--disabled"
                            ]
            , test "an in-flight button fires nothing" <|
                \_ ->
                    button Loading
                        |> Event.simulate Event.click
                        |> Event.toResult
                        |> Expect.err
            ]
        , describe "variants"
            [ test "primary carries the primary class" <|
                \_ ->
                    button NotAsked |> Query.has [ Selector.class "btn--primary" ]
            , test "secondary carries the secondary class" <|
                \_ ->
                    SaveButton.view
                        { state = NotAsked
                        , onSave = Save
                        , label = "Save Draft"
                        , busyLabel = "Saving…"
                        , savedLabel = "Draft saved!"
                        , variant = SaveButton.Secondary
                        }
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has [ Selector.class "btn--secondary" ]
                            , Query.hasNot [ Selector.class "btn--primary" ]
                            ]
            , test "a secondary button's saved state is clickable too" <|
                \_ ->
                    SaveButton.view
                        { state = Success ()
                        , onSave = Save
                        , label = "Save Draft"
                        , busyLabel = "Saving…"
                        , savedLabel = "Draft saved!"
                        , variant = SaveButton.Secondary
                        }
                        |> Query.fromHtml
                        |> Event.simulate Event.click
                        |> Event.expect Save
            ]
        ]
