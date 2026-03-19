module Navigation.Route exposing
    ( ConfirmStatus(..)
    , Route(..)
    , fromUrl
    , toPath
    )

import Url exposing (Url)
import Url.Parser as Parser exposing ((</>), Parser, s, string)


type ConfirmStatus
    = EmailConfirmed
    | EmailConfirmFailed


type Route
    = Home
    | Login
    | Library
    | AntiLibrary
    | WishList
    | ReadingPile
    | LookingForHome
    | BookDetail String
    | Upload
    | Search
    | SettingsConsent
    | SettingsAgeVerification
    | CostTransparency
    | Catalogue
    | ConfirmEmail ConfirmStatus
    | NotFound


parser : Parser (Route -> a) a
parser =
    Parser.oneOf
        [ Parser.map Home Parser.top
        , Parser.map Login (s "login")
        , Parser.map Library (s "library")
        , Parser.map AntiLibrary (s "antilibrary")
        , Parser.map WishList (s "wishlist")
        , Parser.map ReadingPile (s "reading-pile")
        , Parser.map LookingForHome (s "looking-for-home")
        , Parser.map BookDetail (s "books" </> string)
        , Parser.map Upload (s "upload")
        , Parser.map Search (s "search")
        , Parser.map SettingsConsent (s "settings" </> s "consent")
        , Parser.map SettingsAgeVerification (s "settings" </> s "age-verification")
        , Parser.map CostTransparency (s "costs")
        , Parser.map Catalogue (s "catalogue")
        , Parser.map (ConfirmEmail EmailConfirmed) (s "confirm-email" </> s "success")
        , Parser.map (ConfirmEmail EmailConfirmFailed) (s "confirm-email" </> s "error")
        ]


fromUrl : Url -> Route
fromUrl url =
    Parser.parse parser url
        |> Maybe.withDefault NotFound


toPath : Route -> String
toPath route =
    case route of
        Home ->
            "/"

        Login ->
            "/login"

        Library ->
            "/library"

        AntiLibrary ->
            "/antilibrary"

        WishList ->
            "/wishlist"

        ReadingPile ->
            "/reading-pile"

        LookingForHome ->
            "/looking-for-home"

        BookDetail bookId ->
            "/books/" ++ bookId

        Upload ->
            "/upload"

        Search ->
            "/search"

        SettingsConsent ->
            "/settings/consent"

        SettingsAgeVerification ->
            "/settings/age-verification"

        CostTransparency ->
            "/costs"

        Catalogue ->
            "/catalogue"

        ConfirmEmail EmailConfirmed ->
            "/confirm-email/success"

        ConfirmEmail EmailConfirmFailed ->
            "/confirm-email/error"

        NotFound ->
            "/not-found"
