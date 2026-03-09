module Main exposing (main)

import Animation.RoomTransition as RoomTransition
import Animation.SlideTransition as SlideTransition
import Browser
import Browser.Navigation as Nav
import Html exposing (Html, a, div, footer, h1, header, li, main_, nav, p, text, ul)
import Html.Attributes exposing (class, href)
import Navigation.Route as Route exposing (Route(..))
import Page.BookDetail as BookDetail
import Page.Bookshelf.AntiLibrary as AntiLibrary
import Page.Bookshelf.Library as Library
import Page.Bookshelf.ReadingPile as ReadingPile
import Page.Bookshelf.WishList as WishList
import Page.Search as Search
import Page.Settings.AgeVerification as AgeVerification
import Page.Settings.Consent as Consent
import Page.Upload as Upload
import Types.User exposing (AuthToken, User)
import Url exposing (Url)


main : Program () Model Msg
main =
    Browser.application
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        , onUrlChange = UrlChanged
        , onUrlRequest = LinkClicked
        }



-- MODEL


type Page
    = PageHome
    | PageLibrary Library.Model
    | PageAntiLibrary AntiLibrary.Model
    | PageWishList WishList.Model
    | PageReadingPile ReadingPile.Model
    | PageBookDetail BookDetail.Model
    | PageUpload Upload.Model
    | PageSearch Search.Model
    | PageSettingsConsent Consent.Model
    | PageSettingsAgeVerification AgeVerification.Model
    | PageNotFound


type alias Auth =
    { user : User
    , token : AuthToken
    }


type alias Model =
    { key : Nav.Key
    , url : Url
    , route : Route
    , auth : Maybe Auth
    , page : Page
    , previousRoute : Maybe Route
    , transition : Maybe String
    }


init : () -> Url -> Nav.Key -> ( Model, Cmd Msg )
init _ url key =
    let
        route =
            Route.fromUrl url

        ( page, cmd ) =
            initPage route Nothing Nothing
    in
    ( { key = key
      , url = url
      , route = route
      , auth = Nothing
      , page = page
      , previousRoute = Nothing
      , transition = Nothing
      }
    , cmd
    )


initPage : Route -> Maybe Auth -> Maybe Route -> ( Page, Cmd Msg )
initPage route maybeAuth maybePreviousRoute =
    let
        maybeToken =
            Maybe.map .token maybeAuth
    in
    case route of
        Home ->
            ( PageHome, Cmd.none )

        Library ->
            let
                ( model, cmd ) =
                    Library.init maybeToken
            in
            ( PageLibrary model, Cmd.map LibraryMsg cmd )

        AntiLibrary ->
            let
                ( model, cmd ) =
                    AntiLibrary.init maybeToken
            in
            ( PageAntiLibrary model, Cmd.map AntiLibraryMsg cmd )

        WishList ->
            let
                ( model, cmd ) =
                    WishList.init maybeToken
            in
            ( PageWishList model, Cmd.map WishListMsg cmd )

        ReadingPile ->
            let
                ( model, cmd ) =
                    ReadingPile.init maybeToken
            in
            ( PageReadingPile model, Cmd.map ReadingPileMsg cmd )

        BookDetail bookId ->
            let
                ( model, cmd ) =
                    BookDetail.init bookId maybeToken maybePreviousRoute
            in
            ( PageBookDetail model, Cmd.map BookDetailMsg cmd )

        Upload ->
            ( PageUpload Upload.init, Cmd.none )

        Search ->
            ( PageSearch Search.init, Cmd.none )

        SettingsConsent ->
            ( PageSettingsConsent Consent.init, Cmd.none )

        SettingsAgeVerification ->
            ( PageSettingsAgeVerification AgeVerification.init, Cmd.none )

        NotFound ->
            ( PageNotFound, Cmd.none )



-- UPDATE


type Msg
    = LinkClicked Browser.UrlRequest
    | UrlChanged Url
    | LibraryMsg Library.Msg
    | AntiLibraryMsg AntiLibrary.Msg
    | WishListMsg WishList.Msg
    | ReadingPileMsg ReadingPile.Msg
    | BookDetailMsg BookDetail.Msg
    | UploadMsg Upload.Msg
    | SearchMsg Search.Msg
    | ConsentMsg Consent.Msg
    | AgeVerificationMsg AgeVerification.Msg


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        LinkClicked urlRequest ->
            case urlRequest of
                Browser.Internal url ->
                    ( model, Nav.pushUrl model.key (Url.toString url) )

                Browser.External url ->
                    ( model, Nav.load url )

        UrlChanged url ->
            let
                newRoute =
                    Route.fromUrl url

                transition =
                    Just (transitionClass model.route newRoute)

                ( page, cmd ) =
                    initPage newRoute model.auth (Just model.route)
            in
            ( { model
                | url = url
                , route = newRoute
                , page = page
                , previousRoute = Just model.route
                , transition = transition
              }
            , cmd
            )

        LibraryMsg subMsg ->
            case model.page of
                PageLibrary subModel ->
                    let
                        ( newSubModel, subCmd ) =
                            Library.update subMsg subModel
                    in
                    ( { model | page = PageLibrary newSubModel }
                    , Cmd.map LibraryMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        AntiLibraryMsg subMsg ->
            case model.page of
                PageAntiLibrary subModel ->
                    let
                        ( newSubModel, subCmd ) =
                            AntiLibrary.update subMsg subModel
                    in
                    ( { model | page = PageAntiLibrary newSubModel }
                    , Cmd.map AntiLibraryMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        WishListMsg subMsg ->
            case model.page of
                PageWishList subModel ->
                    let
                        ( newSubModel, subCmd ) =
                            WishList.update subMsg subModel
                    in
                    ( { model | page = PageWishList newSubModel }
                    , Cmd.map WishListMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        ReadingPileMsg subMsg ->
            case model.page of
                PageReadingPile subModel ->
                    let
                        ( newSubModel, subCmd ) =
                            ReadingPile.update subMsg subModel
                    in
                    ( { model | page = PageReadingPile newSubModel }
                    , Cmd.map ReadingPileMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        BookDetailMsg subMsg ->
            case model.page of
                PageBookDetail subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd, outMsg ) =
                            BookDetail.update subMsg subModel maybeToken

                        baseModel =
                            { model | page = PageBookDetail newSubModel }

                        baseCmd =
                            Cmd.map BookDetailMsg subCmd
                    in
                    case outMsg of
                        BookDetail.NoOut ->
                            ( baseModel, baseCmd )

                        BookDetail.NavigateTo route ->
                            ( baseModel
                            , Cmd.batch
                                [ baseCmd
                                , Nav.pushUrl model.key (Route.toPath route)
                                ]
                            )

                _ ->
                    ( model, Cmd.none )

        UploadMsg subMsg ->
            case model.page of
                PageUpload subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd ) =
                            Upload.update subMsg subModel maybeToken
                    in
                    ( { model | page = PageUpload newSubModel }
                    , Cmd.map UploadMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        SearchMsg subMsg ->
            case model.page of
                PageSearch subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd ) =
                            Search.update subMsg subModel maybeToken
                    in
                    ( { model | page = PageSearch newSubModel }
                    , Cmd.map SearchMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        ConsentMsg subMsg ->
            case model.page of
                PageSettingsConsent subModel ->
                    let
                        ( newSubModel, subCmd ) =
                            Consent.update subMsg subModel
                    in
                    ( { model | page = PageSettingsConsent newSubModel }
                    , Cmd.map ConsentMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        AgeVerificationMsg subMsg ->
            case model.page of
                PageSettingsAgeVerification subModel ->
                    let
                        ( newSubModel, subCmd ) =
                            AgeVerification.update subMsg subModel
                    in
                    ( { model | page = PageSettingsAgeVerification newSubModel }
                    , Cmd.map AgeVerificationMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )


transitionClass : Route -> Route -> String
transitionClass from to =
    case ( from, to ) of
        ( _, BookDetail _ ) ->
            SlideTransition.slideInRight

        ( BookDetail _, _ ) ->
            SlideTransition.slideOutRight

        _ ->
            RoomTransition.fadeThroughDarkIn



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.none



-- VIEW


view : Model -> Browser.Document Msg
view model =
    { title = pageTitle model.route
    , body =
        [ div [ class "app" ]
            [ viewNav model
            , main_
                [ class
                    ("app__main"
                        ++ (case model.transition of
                                Just t ->
                                    " " ++ t

                                Nothing ->
                                    ""
                           )
                    )
                ]
                [ viewPage model ]
            , viewFooter
            ]
        ]
    }


pageTitle : Route -> String
pageTitle route =
    case route of
        Home ->
            "The Stacks"

        Library ->
            "Library — The Stacks"

        AntiLibrary ->
            "Antilibrary — The Stacks"

        WishList ->
            "Wish List — The Stacks"

        ReadingPile ->
            "Reading Pile — The Stacks"

        BookDetail _ ->
            "Book — The Stacks"

        Upload ->
            "Add a Book — The Stacks"

        Search ->
            "Search — The Stacks"

        SettingsConsent ->
            "Privacy Settings — The Stacks"

        SettingsAgeVerification ->
            "Age Verification — The Stacks"

        NotFound ->
            "Not Found — The Stacks"


viewNav : Model -> Html Msg
viewNav model =
    header [ class "app-header" ]
        [ div [ class "app-header__brand" ]
            [ a [ href "/", class "app-header__logo" ] [ text "The Stacks" ] ]
        , nav [ class "app-nav" ]
            [ ul [ class "app-nav__list" ]
                [ navItem model.route Library "Library"
                , navItem model.route AntiLibrary "Antilibrary"
                , navItem model.route WishList "Wish List"
                , navItem model.route ReadingPile "Reading Pile"
                , navItem model.route Search "Search"
                , navItem model.route Upload "Add Book"
                ]
            ]
        ]


navItem : Route -> Route -> String -> Html Msg
navItem currentRoute targetRoute label =
    let
        isActive =
            currentRoute == targetRoute

        activeClass =
            if isActive then
                "app-nav__item app-nav__item--active"

            else
                "app-nav__item"
    in
    li [ class activeClass ]
        [ a [ href (Route.toPath targetRoute), class "app-nav__link" ]
            [ text label ]
        ]


viewPage : Model -> Html Msg
viewPage model =
    case model.page of
        PageHome ->
            viewHome

        PageLibrary subModel ->
            Html.map LibraryMsg (Library.view subModel)

        PageAntiLibrary subModel ->
            Html.map AntiLibraryMsg (AntiLibrary.view subModel)

        PageWishList subModel ->
            Html.map WishListMsg (WishList.view subModel)

        PageReadingPile subModel ->
            Html.map ReadingPileMsg (ReadingPile.view subModel)

        PageBookDetail subModel ->
            Html.map BookDetailMsg (BookDetail.view subModel)

        PageUpload subModel ->
            Html.map UploadMsg (Upload.view subModel)

        PageSearch subModel ->
            Html.map SearchMsg (Search.view subModel)

        PageSettingsConsent subModel ->
            Html.map ConsentMsg (Consent.view subModel)

        PageSettingsAgeVerification subModel ->
            Html.map AgeVerificationMsg (AgeVerification.view subModel)

        PageNotFound ->
            viewNotFound


viewHome : Html Msg
viewHome =
    div [ class "page page--home" ]
        [ h1 [ class "home__title" ] [ text "The Stacks" ]
        , p [ class "home__subtitle" ]
            [ text "Your personal library, beautifully organised." ]
        , div [ class "home__actions" ]
            [ a [ href (Route.toPath Library), class "btn btn--primary" ]
                [ text "View Library" ]
            , a [ href (Route.toPath Upload), class "btn btn--secondary" ]
                [ text "Add a Book" ]
            ]
        ]


viewNotFound : Html Msg
viewNotFound =
    div [ class "page page--not-found" ]
        [ h1 [] [ text "Page Not Found" ]
        , p [] [ text "The page you're looking for doesn't exist." ]
        , a [ href "/", class "btn btn--primary" ] [ text "Go Home" ]
        ]


viewFooter : Html Msg
viewFooter =
    footer [ class "app-footer" ]
        [ p [ class "app-footer__text" ]
            [ text "The Stacks — open source book management" ]
        ]
