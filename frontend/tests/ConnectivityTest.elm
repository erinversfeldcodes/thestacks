module ConnectivityTest exposing (suite)

{-| — the shell tells the reader when the browser has no connection.


## The defect

Nothing in the app said anything. The page that most needed to was the one
saying least: a shelf fetched with no connection sat in `Loading` and rendered
an empty bookcase, so the reader was told their library was empty. Inferring it
per-page from `Http.NetworkError` would copy the same decision N times, could
only speak AFTER a request had already failed, and would say nothing at all on a
page that happened not to be fetching. So it is answered once, in the shell, on
the `handleSessionExpiry` pattern.


## The seam these tests are aimed at

`Main` is a `Browser.application` whose `Model` embeds an unconstructable
`Nav.Key`, so `update` cannot be driven here (the seam documented in
`SessionExpiryTest`). The chain is:

    window "offline"  →  app.js  →  connectivityChanged port
                      →  ConnectivityChanged Bool
                      →  connectivityFromOnline
                      →  model.connectivity
                      →  viewConnectivity

`port_boundary_to_banner` is the one assertion written in the terms `app.js`
actually speaks: a `navigator.onLine` boolean in, a rendered banner out. It is
not stronger than the two single-end tests — flipping either end reddens those
too — but it is the only one that reads like the contract, so a future change to
what the port's payload MEANS has a place to fail that is about the meaning
rather than about a constructor.

⚠️ **Two hops in that chain are not proved by any test in this file, and saying
so is the point.** A suite that implied otherwise would be worse than a smaller
one:

  - `update` writes the field `view` reads — one line; the compiler types both
    sides, and nothing here exercises it.
  - The JS port name matches the Elm port name. A typo makes `app.ports.…`
    undefined and the `if (app.ports && …)` guard in `app.js` skips the whole
    block **silently**. No Elm test can see this; it is the "built but not
    wired" defect class.

Both are proved by the live drive recorded in issue Progress Notes: the
browser was taken offline, the banner appeared, and it cleared on reconnect.

-}

import Expect
import Html.Attributes as Attr
import Main
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector


suite : Test
suite =
    describe "Connectivity banner"
        [ test "online_renders_nothing: a banner saying everything is fine is a permanent tax to say nothing" <|
            \() ->
                Main.viewConnectivity Main.Online
                    |> Query.fromHtml
                    |> Query.hasNot [ Selector.class "connectivity-banner" ]
        , test "offline_renders_the_banner: with its text, and not merely an empty styled bar" <|
            \() ->
                Main.viewConnectivity Main.Offline
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ Selector.class "connectivity-banner" ]
                        , Query.has [ Selector.attribute (Attr.attribute "data-testid" "connectivity-offline") ]
                        , Query.has [ Selector.text "You are offline." ]
                        ]
        , test "offline_is_announced_politely: a screen reader hears it without losing the reader's place" <|
            \() ->
                Main.viewConnectivity Main.Offline
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ Selector.attribute (Attr.attribute "role" "status") ]
                        , Query.has [ Selector.attribute (Attr.attribute "aria-live" "polite") ]
                        ]
        , test "navigator_online_is_read_the_right_way_round: true is connected" <|
            \() ->
                ( Main.connectivityFromOnline True, Main.connectivityFromOnline False )
                    |> Expect.equal ( Main.Online, Main.Offline )
        , test "port_boundary_to_banner: the value app.js sends, rendered — the contract in one assertion" <|
            \() ->
                Expect.all
                    [ \_ ->
                        Main.viewConnectivity (Main.connectivityFromOnline False)
                            |> Query.fromHtml
                            |> Query.has [ Selector.class "connectivity-banner" ]
                    , \_ ->
                        Main.viewConnectivity (Main.connectivityFromOnline True)
                            |> Query.fromHtml
                            |> Query.hasNot [ Selector.class "connectivity-banner" ]
                    ]
                    ()
        ]
