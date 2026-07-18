module RouteTest exposing (suite)

import Expect
import Navigation.Route as Route exposing (Route(..))
import Test exposing (Test, describe, test)
import Url


fromPath : String -> Route
fromPath path =
    let
        urlStr =
            "http://localhost" ++ path

        maybeUrl =
            Url.fromString urlStr
    in
    case maybeUrl of
        Just url ->
            Route.fromUrl url

        Nothing ->
            NotFound


suite : Test
suite =
    describe "Route"
        [ describe "fromUrl / toPath round-trips"
            [ test "Home" <|
                \_ ->
                    fromPath "/"
                        |> Expect.equal Home
            , test "Library" <|
                \_ ->
                    fromPath "/library"
                        |> Expect.equal Library
            , test "AntiLibrary" <|
                \_ ->
                    fromPath "/antilibrary"
                        |> Expect.equal AntiLibrary
            , test "WishList" <|
                \_ ->
                    fromPath "/wishlist"
                        |> Expect.equal WishList
            , test "ReadingPile" <|
                \_ ->
                    fromPath "/reading-pile"
                        |> Expect.equal ReadingPile
            , test "LookingForHome" <|
                \_ ->
                    fromPath "/looking-for-home"
                        |> Expect.equal LookingForHome
            , test "BookDetail" <|
                \_ ->
                    fromPath "/books/abc123"
                        |> Expect.equal (BookDetail "abc123")
            , test "ForgotPassword" <|
                \_ ->
                    fromPath "/forgot-password"
                        |> Expect.equal ForgotPassword
            , test "ResetPassword carries the token" <|
                \_ ->
                    fromPath "/reset-password/tok-abc123"
                        |> Expect.equal (ResetPassword "tok-abc123")
            , test "ForgotPassword toPath round-trips" <|
                \_ ->
                    Route.toPath ForgotPassword
                        |> Expect.equal "/forgot-password"
            , test "ResetPassword toPath round-trips" <|
                \_ ->
                    Route.toPath (ResetPassword "tok-abc123")
                        |> Expect.equal "/reset-password/tok-abc123"
            , test "Upload" <|
                \_ ->
                    fromPath "/upload"
                        |> Expect.equal Upload
            , test "Search" <|
                \_ ->
                    fromPath "/search"
                        |> Expect.equal Search
            , test "SettingsConsent" <|
                \_ ->
                    fromPath "/settings/consent"
                        |> Expect.equal SettingsConsent
            , test "Catalogue" <|
                \_ ->
                    fromPath "/catalogue"
                        |> Expect.equal Catalogue
            , test "Metrics" <|
                \_ ->
                    fromPath "/metrics"
                        |> Expect.equal Metrics
            , test "About" <|
                \_ ->
                    fromPath "/about"
                        |> Expect.equal About
            , test "Insights" <|
                \_ ->
                    fromPath "/me/insights"
                        |> Expect.equal Insights
            , test "AdminBookModeration" <|
                \_ ->
                    fromPath "/admin/book-moderation"
                        |> Expect.equal AdminBookModeration
            , test "unknown path returns NotFound" <|
                \_ ->
                    fromPath "/does-not-exist"
                        |> Expect.equal NotFound
            ]
        , describe "toPath"
            [ test "Home path" <|
                \_ ->
                    Route.toPath Home
                        |> Expect.equal "/"
            , test "Library path" <|
                \_ ->
                    Route.toPath Library
                        |> Expect.equal "/library"
            , test "AntiLibrary path" <|
                \_ ->
                    Route.toPath AntiLibrary
                        |> Expect.equal "/antilibrary"
            , test "WishList path" <|
                \_ ->
                    Route.toPath WishList
                        |> Expect.equal "/wishlist"
            , test "ReadingPile path" <|
                \_ ->
                    Route.toPath ReadingPile
                        |> Expect.equal "/reading-pile"
            , test "LookingForHome path" <|
                \_ ->
                    Route.toPath LookingForHome
                        |> Expect.equal "/looking-for-home"
            , test "BookDetail path" <|
                \_ ->
                    Route.toPath (BookDetail "xyz")
                        |> Expect.equal "/books/xyz"
            , test "Upload path" <|
                \_ ->
                    Route.toPath Upload
                        |> Expect.equal "/upload"
            , test "Search path" <|
                \_ ->
                    Route.toPath Search
                        |> Expect.equal "/search"
            , test "SettingsConsent path" <|
                \_ ->
                    Route.toPath SettingsConsent
                        |> Expect.equal "/settings/consent"
            , test "Catalogue path" <|
                \_ ->
                    Route.toPath Catalogue
                        |> Expect.equal "/catalogue"
            , test "Metrics path" <|
                \_ ->
                    Route.toPath Metrics
                        |> Expect.equal "/metrics"
            , test "About path" <|
                \_ ->
                    Route.toPath About
                        |> Expect.equal "/about"
            , test "Insights path" <|
                \_ ->
                    Route.toPath Insights
                        |> Expect.equal "/me/insights"
            , test "AdminBookModeration path" <|
                \_ ->
                    Route.toPath AdminBookModeration
                        |> Expect.equal "/admin/book-moderation"
            ]
        ]
