module DoorArrivalTest exposing (suite)

{-| Issue #364 — the login door dolly-shot plays again, driven from the shell.

`Main.viewArrivalDoor` renders the door scene layers over the destination page
for exactly the `Arriving` window, and nothing at either end of it. That is what
gives `Arriving` an observable job: #359 navigated away from the login scene on
the same update that decoded the `200`, so the port had no elements left to
animate (`animationsStarted=0`). Rendering the layers from the shell puts the
ids the port targets back on screen — over the page the reader just landed on —
without ever putting the credential downstream of the animation.

⚠️ This is a SEPARATE harness from `PersistFirstLoginTest` on purpose. That
suite has no animation-finished message by design — its absence IS the
occluded-window simulation — so a door-render test must not be smuggled into it
(Issue #364 reviewer context). The persist-first guarantee and the door's
presence are proved independently.


## Why these assertions are not vacuous

The `Arriving` positive is paired with a `Authenticated`/`Anonymous` negative
control in the same suite: a bare "the door is absent" passes just as happily
when the view crashed to `text ""` or the class was renamed. And `Arriving`
asserts the actual dolly target (`#bookshelf`, the layer `app.js` scales up and
fades) is present, not merely the wrapper — a wrapper with no layers would
animate nothing and still satisfy a class-only check.


## Mutation probe

Making `viewArrivalDoor` ignore its argument (`viewArrivalDoor _ = text ""`)
reddens `door_renders_while_arriving`. Making it render the door for every state
(`viewArrivalDoor _ = <the Arriving branch>`) reddens both
`no_door_once_authenticated` and `no_door_while_anonymous`.

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
    describe "The arrival door renders from the shell (#364)"
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
