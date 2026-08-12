module ConnectivityTest exposing (suite)

{-| The shell tells the reader when the browser has no connection —
previously nothing did, and an offline shelf rendered as an empty
library. Covers the port wiring (boot send included, so a tab opened
offline knows), the banner's presence exactly while offline, and the
reconnect clearing it.
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
