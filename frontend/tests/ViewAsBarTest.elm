module ViewAsBarTest exposing (suite)

import Components.ViewAsBar as ViewAsBar
import Expect
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Url exposing (Url)


{-| Build a Url from a full string; falls back to a bare localhost Url if
parsing somehow fails so the test surfaces a clear assertion, not a crash.
-}
urlFrom : String -> Url
urlFrom str =
    case Url.fromString str of
        Just url ->
            url

        Nothing ->
            { protocol = Url.Http
            , host = "localhost"
            , port_ = Nothing
            , path = "/"
            , query = Nothing
            , fragment = Nothing
            }


suite : Test
suite =
    describe "Components.ViewAsBar"
        [ describe "banner render"
            [ test "renders the bar when view_as is present" <|
                \_ ->
                    urlFrom "http://localhost/shelf/library?view_as=platform"
                        |> ViewAsBar.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.class "view-as-bar" ]
            , test "renders an Exit preview link when view_as is present" <|
                \_ ->
                    urlFrom "http://localhost/shelf/library?view_as=platform"
                        |> ViewAsBar.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Exit preview" ]
            , test "renders nothing when view_as is absent" <|
                \_ ->
                    urlFrom "http://localhost/shelf/library"
                        |> ViewAsBar.view
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.class "view-as-bar" ]
            , test "unauthenticated perspective renders the 'Not logged in' label (build c)" <|
                \_ ->
                    urlFrom "http://localhost/shelf/library?view_as=unauthenticated"
                        |> ViewAsBar.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Viewing as: Not logged in" ]
            ]
        , describe "getViewAs"
            [ test "extracts the view_as value from the query" <|
                \_ ->
                    urlFrom "http://localhost/shelf/library?view_as=platform"
                        |> ViewAsBar.getViewAs
                        |> Expect.equal (Just "platform")
            , test "returns Nothing when view_as is absent" <|
                \_ ->
                    urlFrom "http://localhost/shelf/library?foo=bar"
                        |> ViewAsBar.getViewAs
                        |> Expect.equal Nothing
            , test "extracts view_as when mixed with other params" <|
                \_ ->
                    urlFrom "http://localhost/shelf/library?foo=bar&view_as=unauthenticated"
                        |> ViewAsBar.getViewAs
                        |> Expect.equal (Just "unauthenticated")
            ]
        , describe "removeViewAs"
            [ test "drops the view_as param and keeps the path when it was the only param" <|
                \_ ->
                    urlFrom "http://localhost/shelf/library?view_as=platform"
                        |> ViewAsBar.removeViewAs
                        |> Expect.equal "/shelf/library"
            , test "keeps other params when removing view_as" <|
                \_ ->
                    urlFrom "http://localhost/shelf/library?foo=bar&view_as=platform"
                        |> ViewAsBar.removeViewAs
                        |> Expect.equal "/shelf/library?foo=bar"
            ]
        ]
