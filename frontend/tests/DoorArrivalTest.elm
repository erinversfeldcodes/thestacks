module DoorArrivalTest exposing (suite)

{-| The login door dolly-shot plays again, driven from the SHELL.
Navigating away from the login scene on the same update that decodes
the 200 unmounts the page's layers before the animation port's rAF
callback runs — zero animations started. `Main.viewArrivalDoor` renders
the scene over the destination for exactly the `Arriving` window;
these tests pin that window at both ends.
-}

import Html.Attributes as Attr
import Main
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.User exposing (User)


readerUser : User
readerUser =
    { id = "u1"
    , email = "reader@stacks.dev"
    , displayName = "A Reader"
    , handle = "a_reader"
    , role = "user"
    , countryCode = Nothing
    , city = Nothing
    , consentAnalytics = False
    , consentWritingAssistant = False
    }


readerAuth : Main.Auth
readerAuth =
    { user = readerUser, token = "jwt-token" }


suite : Test
suite =
    describe "The arrival door renders from the shell"
        [ test "door_renders_while_arriving: the dolly-shot scene is present while AuthState is Arriving" <|
            \() ->
                Main.viewArrivalDoor (Main.Arriving readerAuth)
                    |> Query.fromHtml
                    |> Query.has
                        [ Selector.class "arrival-door"
                        , Selector.attribute (Attr.attribute "data-testid" "arrival-door")
                        ]
        , test "door_animates_the_bookshelf: the layer the port dollies through is rendered with the id it targets" <|
            \() ->
                Main.viewArrivalDoor (Main.Arriving readerAuth)
                    |> Query.fromHtml
                    |> Query.find [ Selector.class "layer-bookshelf" ]
                    |> Query.has [ Selector.id "bookshelf" ]
        , test "no_door_once_authenticated: the door is removed the instant the arrival settles" <|
            \() ->
                Main.viewArrivalDoor (Main.Authenticated readerAuth)
                    |> Query.fromHtml
                    |> Query.hasNot [ Selector.class "arrival-door" ]
        , test "no_door_while_anonymous: a signed-out shell shows no arrival door" <|
            \() ->
                Main.viewArrivalDoor Main.Anonymous
                    |> Query.fromHtml
                    |> Query.hasNot [ Selector.class "arrival-door" ]
        ]
