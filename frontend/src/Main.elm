port module Main exposing (main)

import Animation.RoomTransition as RoomTransition
import Animation.SlideTransition as SlideTransition
import Browser
import Browser.Navigation as Nav
import Html exposing (Html, a, div, footer, h1, header, li, main_, nav, p, text, ul)
import Html.Attributes exposing (class, href)
import Json.Decode as Decode
import Navigation.Route as Route exposing (Route(..))
import Navigation.SwipeNavigation as SwipeNavigation
import Page.BookDetail as BookDetail
import Page.Bookshelf.AntiLibrary as AntiLibrary
import Page.Bookshelf.Library as Library
import Page.Bookshelf.LookingForHome as LookingForHome
import Page.Bookshelf.ReadingPile as ReadingPile
import Page.Bookshelf.WishList as WishList
import Page.Search as Search
import Page.Settings.AgeVerification as AgeVerification
import Page.Settings.Consent as Consent
import Page.Upload as Upload
import Types.User exposing (AuthToken, User)
import Url exposing (Url)


port onSwipe : (Decode.Value -> msg) -> Sub msg


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
    | PageLookingForHome LookingForHome.Model
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

        LookingForHome ->
            let
                ( model, cmd ) =
                    LookingForHome.init maybeToken
            in
            ( PageLookingForHome model, Cmd.map LookingForHomeMsg cmd )

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
    | LookingForHomeMsg LookingForHome.Msg
    | BookDetailMsg BookDetail.Msg
    | UploadMsg Upload.Msg
    | SearchMsg Search.Msg
    | ConsentMsg Consent.Msg
    | AgeVerificationMsg AgeVerification.Msg
    | SwipeReceived String
    | SwipeIgnored


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
                        ( newSubModel, subCmd, outMsg ) =
                            Library.update subMsg subModel

                        baseModel =
                            { model | page = PageLibrary newSubModel }

                        baseCmd =
                            Cmd.map LibraryMsg subCmd
                    in
                    case outMsg of
                        Library.NoOut ->
                            ( baseModel, baseCmd )

                        Library.NavigateTo route ->
                            ( baseModel
                            , Cmd.batch
                                [ baseCmd
                                , Nav.pushUrl model.key (Route.toPath route)
                                ]
                            )

                _ ->
                    ( model, Cmd.none )

        AntiLibraryMsg subMsg ->
            case model.page of
                PageAntiLibrary subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            AntiLibrary.update subMsg subModel

                        baseModel =
                            { model | page = PageAntiLibrary newSubModel }

                        baseCmd =
                            Cmd.map AntiLibraryMsg subCmd
                    in
                    case outMsg of
                        AntiLibrary.NoOut ->
                            ( baseModel, baseCmd )

                        AntiLibrary.NavigateTo route ->
                            ( baseModel
                            , Cmd.batch
                                [ baseCmd
                                , Nav.pushUrl model.key (Route.toPath route)
                                ]
                            )

                _ ->
                    ( model, Cmd.none )

        WishListMsg subMsg ->
            case model.page of
                PageWishList subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            WishList.update subMsg subModel

                        baseModel =
                            { model | page = PageWishList newSubModel }

                        baseCmd =
                            Cmd.map WishListMsg subCmd
                    in
                    case outMsg of
                        WishList.NoOut ->
                            ( baseModel, baseCmd )

                        WishList.NavigateTo route ->
                            ( baseModel
                            , Cmd.batch
                                [ baseCmd
                                , Nav.pushUrl model.key (Route.toPath route)
                                ]
                            )

                _ ->
                    ( model, Cmd.none )

        ReadingPileMsg subMsg ->
            case model.page of
                PageReadingPile subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            ReadingPile.update subMsg subModel

                        baseModel =
                            { model | page = PageReadingPile newSubModel }

                        baseCmd =
                            Cmd.map ReadingPileMsg subCmd
                    in
                    case outMsg of
                        ReadingPile.NoOut ->
                            ( baseModel, baseCmd )

                        ReadingPile.NavigateTo route ->
                            ( baseModel
                            , Cmd.batch
                                [ baseCmd
                                , Nav.pushUrl model.key (Route.toPath route)
                                ]
                            )

                _ ->
                    ( model, Cmd.none )

        LookingForHomeMsg subMsg ->
            case model.page of
                PageLookingForHome subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            LookingForHome.update subMsg subModel

                        baseModel =
                            { model | page = PageLookingForHome newSubModel }

                        baseCmd =
                            Cmd.map LookingForHomeMsg subCmd
                    in
                    case outMsg of
                        LookingForHome.NoOut ->
                            ( baseModel, baseCmd )

                        LookingForHome.NavigateTo route ->
                            ( baseModel
                            , Cmd.batch
                                [ baseCmd
                                , Nav.pushUrl model.key (Route.toPath route)
                                ]
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
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd ) =
                            Consent.update subMsg subModel maybeToken
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
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd ) =
                            AgeVerification.update subMsg subModel maybeToken
                    in
                    ( { model | page = PageSettingsAgeVerification newSubModel }
                    , Cmd.map AgeVerificationMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        SwipeReceived direction ->
            let
                maybeNext =
                    if direction == "left" then
                        SwipeNavigation.swipeLeft model.route

                    else
                        SwipeNavigation.swipeRight model.route
            in
            case maybeNext of
                Just nextRoute ->
                    ( model, Nav.pushUrl model.key (Route.toPath nextRoute) )

                Nothing ->
                    ( model, Cmd.none )

        SwipeIgnored ->
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
    onSwipe decodeSwipe


decodeSwipe : Decode.Value -> Msg
decodeSwipe value =
    case Decode.decodeValue Decode.string value of
        Ok direction ->
            SwipeReceived direction

        Err _ ->
            SwipeIgnored



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

        LookingForHome ->
            "Looking for a Home — The Stacks"

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
                , navItem model.route LookingForHome "Looking for a Home"
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

        PageLookingForHome subModel ->
            Html.map LookingForHomeMsg (LookingForHome.view subModel)

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
