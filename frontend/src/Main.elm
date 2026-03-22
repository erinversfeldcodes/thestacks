port module Main exposing (main)

import Animation.RoomTransition as RoomTransition
import Animation.SlideTransition as SlideTransition
import Api
import Browser
import Browser.Events
import Browser.Navigation as Nav
import Components.UserMenu as UserMenu
import Html exposing (Html, a, div, footer, h1, header, li, main_, nav, p, text, ul)
import Html.Attributes exposing (class, href)
import Json.Decode as Decode
import Json.Encode
import Navigation.Route as Route exposing (ConfirmStatus(..), Route(..), isSettingsRoute)
import Navigation.SwipeNavigation as SwipeNavigation
import Page.BookDetail as BookDetail
import Page.Bookshelf as Bookshelf
import Page.Bookshelf.LookingForHome as LookingForHome
import Page.Bookshelf.ReadingPile as ReadingPile
import Page.Catalogue as Catalogue
import Page.CostTransparency as CostTransparency
import Page.Login as Login
import Page.Search as Search
import Page.Settings as Settings
import Page.Settings.AgeVerification as AgeVerification
import Page.Settings.Consent as Consent
import Page.Settings.Notifications as Notifications
import Page.Settings.Password as Password
import Page.Settings.Profile as Profile
import Page.Upload as Upload
import Types.User exposing (AuthToken, User)
import Url exposing (Url)


port onSwipe : (Decode.Value -> msg) -> Sub msg


port playLoginTransition : Json.Encode.Value -> Cmd msg


port onLoginTransitionComplete : (Decode.Value -> msg) -> Sub msg


port saveAuth : Json.Encode.Value -> Cmd msg


port clearAuth : () -> Cmd msg


main : Program Decode.Value Model Msg
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
    | PageLogin Login.Model
    | PageBookshelf Bookshelf.Model
    | PageReadingPile ReadingPile.Model
    | PageLookingForHome LookingForHome.Model
    | PageBookDetail BookDetail.Model
    | PageUpload Upload.Model
    | PageSearch Search.Model
    | PageSettingsConsent Consent.Model
    | PageSettingsAgeVerification AgeVerification.Model
    | PageSettingsProfile Profile.Model
    | PageSettingsPassword Password.Model
    | PageSettingsNotifications Notifications.Model
    | PageCostTransparency CostTransparency.Model
    | PageCatalogue Catalogue.Model
    | PageConfirmEmail ConfirmStatus
    | PageNotFound


type alias Auth =
    { user : User
    , token : AuthToken
    }


type alias BookDetailOverlay =
    { bookId : String
    , detail : BookDetail.Model
    }


type alias Model =
    { key : Nav.Key
    , url : Url
    , route : Route
    , auth : Maybe Auth
    , page : Page
    , previousRoute : Maybe Route
    , transition : Maybe String
    , pendingAuthResponse : Maybe Api.AuthResponse
    , bookDetailOverlay : Maybe BookDetailOverlay
    , userMenu : UserMenu.Model
    }


init : Decode.Value -> Url -> Nav.Key -> ( Model, Cmd Msg )
init flags url key =
    let
        maybeAuth =
            decodeFlags flags

        route =
            Route.fromUrl url

        ( page, cmd ) =
            initPage route maybeAuth Nothing
    in
    ( { key = key
      , url = url
      , route = route
      , auth = maybeAuth
      , page = page
      , previousRoute = Nothing
      , transition = Nothing
      , pendingAuthResponse = Nothing
      , bookDetailOverlay = Nothing
      , userMenu = UserMenu.init
      }
    , cmd
    )


decodeFlags : Decode.Value -> Maybe Auth
decodeFlags flags =
    let
        authDecoder =
            Decode.map4
                (\token userId email displayName ->
                    { user =
                        { id = userId
                        , email = email
                        , displayName = displayName
                        , role = "user"
                        , countryCode = Nothing
                        , city = Nothing
                        }
                    , token = token
                    }
                )
                (Decode.field "token" Decode.string)
                (Decode.field "userId" Decode.string)
                (Decode.field "email" Decode.string)
                (Decode.field "displayName" Decode.string)
    in
    Decode.decodeValue authDecoder flags
        |> Result.toMaybe


requiresAuth : Route -> Bool
requiresAuth route =
    case route of
        Home ->
            False

        Login ->
            False

        CostTransparency ->
            False

        Catalogue ->
            False

        BookDetail _ ->
            False

        ConfirmEmail _ ->
            False

        NotFound ->
            False

        _ ->
            True


initPage : Route -> Maybe Auth -> Maybe Route -> ( Page, Cmd Msg )
initPage route maybeAuth maybePreviousRoute =
    if requiresAuth route && maybeAuth == Nothing then
        ( PageLogin Login.init, Cmd.none )

    else
        initPageAuthenticated route maybeAuth maybePreviousRoute


initBookshelf : Bookshelf.Config -> Maybe Auth -> ( Page, Cmd Msg )
initBookshelf config maybeAuth =
    let
        maybeToken =
            Maybe.map .token maybeAuth

        userId =
            maybeAuth |> Maybe.map (.user >> .id) |> Maybe.withDefault ""

        ( model, cmd ) =
            Bookshelf.init config maybeToken userId
    in
    ( PageBookshelf model, Cmd.map BookshelfMsg cmd )


initPageAuthenticated : Route -> Maybe Auth -> Maybe Route -> ( Page, Cmd Msg )
initPageAuthenticated route maybeAuth maybePreviousRoute =
    let
        maybeToken =
            Maybe.map .token maybeAuth
    in
    case route of
        Home ->
            ( PageHome, Cmd.none )

        Login ->
            ( PageLogin Login.init, Cmd.none )

        Library ->
            initBookshelf Bookshelf.libraryConfig maybeAuth

        AntiLibrary ->
            initBookshelf Bookshelf.antiLibraryConfig maybeAuth

        WishList ->
            initBookshelf Bookshelf.wishListConfig maybeAuth

        ReadingPile ->
            let
                ( model, cmd ) =
                    ReadingPile.init maybeToken
            in
            ( PageReadingPile model, Cmd.map ReadingPileMsg cmd )

        LookingForHome ->
            let
                ( subModel, subCmd ) =
                    LookingForHome.init maybeToken
            in
            ( PageLookingForHome subModel, Cmd.map LookingForHomeMsg subCmd )

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

        CostTransparency ->
            let
                ( model, cmd ) =
                    CostTransparency.init
            in
            ( PageCostTransparency model, Cmd.map CostTransparencyMsg cmd )

        Catalogue ->
            let
                ( model, cmd ) =
                    Catalogue.init maybeToken
            in
            ( PageCatalogue model, Cmd.map CatalogueMsg cmd )

        Settings ->
            let
                profileModel =
                    case maybeAuth of
                        Just auth ->
                            Profile.init auth.user

                        Nothing ->
                            Profile.init { id = "", email = "", displayName = "", role = "user", countryCode = Nothing, city = Nothing }
            in
            ( PageSettingsProfile profileModel, Cmd.none )

        SettingsProfile ->
            let
                profileModel =
                    case maybeAuth of
                        Just auth ->
                            Profile.init auth.user

                        Nothing ->
                            Profile.init { id = "", email = "", displayName = "", role = "user", countryCode = Nothing, city = Nothing }
            in
            ( PageSettingsProfile profileModel, Cmd.none )

        SettingsPassword ->
            ( PageSettingsPassword Password.init, Cmd.none )

        SettingsNotifications ->
            ( PageSettingsNotifications Notifications.init, Cmd.none )

        ConfirmEmail status ->
            ( PageConfirmEmail status, Cmd.none )

        NotFound ->
            ( PageNotFound, Cmd.none )


encodeAuth : Auth -> Json.Encode.Value
encodeAuth auth =
    Json.Encode.object
        [ ( "token", Json.Encode.string auth.token )
        , ( "userId", Json.Encode.string auth.user.id )
        , ( "email", Json.Encode.string auth.user.email )
        , ( "displayName", Json.Encode.string auth.user.displayName )
        ]



-- UPDATE


type Msg
    = LinkClicked Browser.UrlRequest
    | UrlChanged Url
    | LoginMsg Login.Msg
    | LoginTransitionCompleted
    | BookshelfMsg Bookshelf.Msg
    | ReadingPileMsg ReadingPile.Msg
    | LookingForHomeMsg LookingForHome.Msg
    | BookDetailMsg BookDetail.Msg
    | UploadMsg Upload.Msg
    | SearchMsg Search.Msg
    | ConsentMsg Consent.Msg
    | AgeVerificationMsg AgeVerification.Msg
    | ProfileMsg Profile.Msg
    | PasswordMsg Password.Msg
    | NotificationsMsg Notifications.Msg
    | CostTransparencyMsg CostTransparency.Msg
    | CatalogueMsg Catalogue.Msg
    | UserMenuMsg UserMenu.Msg
    | LogoutCompleted (Result () ())
    | SettingsMobileNavChanged String
    | SwipeReceived String
    | SwipeIgnored
    | OpenBookOverlay String
    | CloseBookOverlay
    | OverlayBookDetailMsg BookDetail.Msg
    | EscapePressed


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        LinkClicked urlRequest ->
            case urlRequest of
                Browser.Internal url ->
                    case Route.fromUrl url of
                        BookDetail bookId ->
                            let
                                ( overlayModel, overlayCmd ) =
                                    openOverlay model bookId
                            in
                            ( overlayModel, overlayCmd )

                        _ ->
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
                , userMenu = UserMenu.init
              }
            , cmd
            )

        LoginMsg subMsg ->
            case model.page of
                PageLogin subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            Login.update subMsg subModel

                        baseModel =
                            { model | page = PageLogin newSubModel }

                        baseCmd =
                            Cmd.map LoginMsg subCmd
                    in
                    case outMsg of
                        Login.NoOut ->
                            ( baseModel, baseCmd )

                        Login.StartTransition authResponse ->
                            ( { baseModel | pendingAuthResponse = Just authResponse }
                            , Cmd.batch
                                [ baseCmd
                                , playLoginTransition
                                    (Json.Encode.object
                                        [ ( "duration", Json.Encode.int 4000 ) ]
                                    )
                                ]
                            )

                        Login.LoggedIn authResponse ->
                            let
                                auth =
                                    { user =
                                        { id = authResponse.userId
                                        , email = authResponse.email
                                        , displayName = authResponse.displayName
                                        , role = "user"
                                        , countryCode = Nothing
                                        , city = Nothing
                                        }
                                    , token = authResponse.token
                                    }
                            in
                            ( { baseModel | auth = Just auth, pendingAuthResponse = Nothing }
                            , Cmd.batch [ baseCmd, saveAuth (encodeAuth auth), Nav.pushUrl model.key (Route.toPath AntiLibrary) ]
                            )

                _ ->
                    ( model, Cmd.none )

        LoginTransitionCompleted ->
            case ( model.page, model.pendingAuthResponse ) of
                ( PageLogin subModel, Just authResponse ) ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            Login.update (Login.TransitionCompleted authResponse) subModel

                        baseModel =
                            { model | page = PageLogin newSubModel }

                        baseCmd =
                            Cmd.map LoginMsg subCmd
                    in
                    case outMsg of
                        Login.LoggedIn ar ->
                            let
                                auth =
                                    { user =
                                        { id = ar.userId
                                        , email = ar.email
                                        , displayName = ar.displayName
                                        , role = "user"
                                        , countryCode = Nothing
                                        , city = Nothing
                                        }
                                    , token = ar.token
                                    }
                            in
                            ( { baseModel | auth = Just auth, pendingAuthResponse = Nothing }
                            , Cmd.batch [ baseCmd, saveAuth (encodeAuth auth), Nav.pushUrl model.key (Route.toPath AntiLibrary) ]
                            )

                        _ ->
                            ( baseModel, baseCmd )

                _ ->
                    ( model, Cmd.none )

        BookshelfMsg subMsg ->
            case model.page of
                PageBookshelf subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            Bookshelf.update subMsg subModel

                        baseModel =
                            { model | page = PageBookshelf newSubModel }

                        baseCmd =
                            Cmd.map BookshelfMsg subCmd
                    in
                    case outMsg of
                        Bookshelf.NoOut ->
                            ( baseModel, baseCmd )

                        Bookshelf.NavigateTo (BookDetail bookId) ->
                            let
                                ( overlayModel, overlayCmd ) =
                                    openOverlay baseModel bookId
                            in
                            ( overlayModel
                            , Cmd.batch [ baseCmd, overlayCmd ]
                            )

                        Bookshelf.NavigateTo route ->
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

                        ReadingPile.NavigateTo (BookDetail bookId) ->
                            let
                                ( overlayModel, overlayCmd ) =
                                    openOverlay baseModel bookId
                            in
                            ( overlayModel
                            , Cmd.batch [ baseCmd, overlayCmd ]
                            )

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

                        LookingForHome.NavigateTo (Route.BookDetail bookId) ->
                            openOverlay baseModel bookId

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

                        BookDetail.RequestCloseOverlay ->
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

                        ( newSubModel, subCmd, outMsg ) =
                            Upload.update subMsg subModel maybeToken

                        baseModel =
                            { model | page = PageUpload newSubModel }

                        baseCmd =
                            Cmd.map UploadMsg subCmd
                    in
                    case outMsg of
                        Upload.NoOut ->
                            ( baseModel, baseCmd )

                        Upload.NavigateTo route ->
                            ( baseModel
                            , Cmd.batch
                                [ baseCmd
                                , Nav.pushUrl model.key (Route.toPath route)
                                ]
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

        ProfileMsg subMsg ->
            case model.page of
                PageSettingsProfile subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd ) =
                            Profile.update subMsg subModel maybeToken
                    in
                    ( { model | page = PageSettingsProfile newSubModel }
                    , Cmd.map ProfileMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        PasswordMsg subMsg ->
            case model.page of
                PageSettingsPassword subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd ) =
                            Password.update subMsg subModel maybeToken
                    in
                    ( { model | page = PageSettingsPassword newSubModel }
                    , Cmd.map PasswordMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        NotificationsMsg subMsg ->
            case model.page of
                PageSettingsNotifications subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd ) =
                            Notifications.update subMsg subModel maybeToken
                    in
                    ( { model | page = PageSettingsNotifications newSubModel }
                    , Cmd.map NotificationsMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        CostTransparencyMsg subMsg ->
            case model.page of
                PageCostTransparency subModel ->
                    let
                        ( newSubModel, subCmd ) =
                            CostTransparency.update subMsg subModel
                    in
                    ( { model | page = PageCostTransparency newSubModel }
                    , Cmd.map CostTransparencyMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        CatalogueMsg subMsg ->
            case model.page of
                PageCatalogue subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd ) =
                            Catalogue.update subMsg subModel maybeToken
                    in
                    ( { model | page = PageCatalogue newSubModel }
                    , Cmd.map CatalogueMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        OpenBookOverlay bookId ->
            openOverlay model bookId

        CloseBookOverlay ->
            ( { model | bookDetailOverlay = Nothing }, Cmd.none )

        OverlayBookDetailMsg subMsg ->
            case model.bookDetailOverlay of
                Just overlay ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newDetail, subCmd, outMsg ) =
                            BookDetail.update subMsg overlay.detail maybeToken

                        updatedOverlay =
                            { overlay | detail = newDetail }
                    in
                    case outMsg of
                        BookDetail.RequestCloseOverlay ->
                            ( { model | bookDetailOverlay = Nothing }
                            , Cmd.none
                            )

                        BookDetail.NavigateTo route ->
                            ( { model | bookDetailOverlay = Nothing }
                            , Nav.pushUrl model.key (Route.toPath route)
                            )

                        BookDetail.NoOut ->
                            ( { model | bookDetailOverlay = Just updatedOverlay }
                            , Cmd.map OverlayBookDetailMsg subCmd
                            )

                Nothing ->
                    ( model, Cmd.none )

        UserMenuMsg subMsg ->
            let
                ( newUserMenu, outMsg ) =
                    UserMenu.update subMsg model.userMenu
            in
            case outMsg of
                UserMenu.NoOut ->
                    ( { model | userMenu = newUserMenu }, Cmd.none )

                UserMenu.NavigateToSettings ->
                    ( { model | userMenu = newUserMenu }
                    , Nav.pushUrl model.key (Route.toPath SettingsProfile)
                    )

                UserMenu.SignOut ->
                    let
                        logoutCmd =
                            case model.auth of
                                Just auth ->
                                    Api.logout auth.token (\_ -> LogoutCompleted (Ok ()))

                                Nothing ->
                                    Cmd.none
                    in
                    ( { model | userMenu = newUserMenu, auth = Nothing, page = PageLogin Login.init }
                    , Cmd.batch
                        [ logoutCmd
                        , clearAuth ()
                        , Nav.pushUrl model.key (Route.toPath Login)
                        ]
                    )

        LogoutCompleted _ ->
            ( model, Cmd.none )

        SettingsMobileNavChanged path ->
            ( model, Nav.pushUrl model.key path )

        EscapePressed ->
            case model.bookDetailOverlay of
                Just _ ->
                    ( { model | bookDetailOverlay = Nothing }, Cmd.none )

                Nothing ->
                    let
                        ( newUserMenu, _ ) =
                            UserMenu.update UserMenu.Close model.userMenu
                    in
                    ( { model | userMenu = newUserMenu }, Cmd.none )

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


{-| Open the book detail overlay for a given book ID.
Initialises a BookDetail.Model and fires the API fetch command.
-}
openOverlay : Model -> String -> ( Model, Cmd Msg )
openOverlay model bookId =
    let
        maybeToken =
            Maybe.map .token model.auth

        ( detailModel, detailCmd ) =
            BookDetail.init bookId maybeToken (Just model.route)

        overlay =
            { bookId = bookId
            , detail = detailModel
            }
    in
    ( { model | bookDetailOverlay = Just overlay }
    , Cmd.map OverlayBookDetailMsg detailCmd
    )


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
    Sub.batch
        [ onSwipe decodeSwipe
        , onLoginTransitionComplete (\_ -> LoginTransitionCompleted)
        , Browser.Events.onKeyDown
            (Decode.field "key" Decode.string
                |> Decode.andThen
                    (\key ->
                        if key == "Escape" then
                            Decode.succeed EscapePressed

                        else
                            Decode.fail "not escape"
                    )
            )
        ]


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
        [ viewOverlay model
        , div [ class "app" ]
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

        Login ->
            "Sign In — The Stacks"

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

        Settings ->
            "Settings — The Stacks"

        SettingsProfile ->
            "Profile — The Stacks"

        SettingsPassword ->
            "Password — The Stacks"

        SettingsNotifications ->
            "Notifications — The Stacks"

        SettingsConsent ->
            "Privacy Settings — The Stacks"

        SettingsAgeVerification ->
            "Age Verification — The Stacks"

        CostTransparency ->
            "Cost Transparency — The Stacks"

        Catalogue ->
            "Catalogue — The Stacks"

        ConfirmEmail EmailConfirmed ->
            "Email Confirmed — The Stacks"

        ConfirmEmail EmailConfirmFailed ->
            "Confirmation Failed — The Stacks"

        NotFound ->
            "Not Found — The Stacks"


viewNav : Model -> Html Msg
viewNav model =
    header [ class "app-header" ]
        [ div [ class "app-header__brand app-nav__dropdown" ]
            [ a [ href "/", class "app-header__logo" ] [ text "The Stacks" ]
            , ul [ class "app-nav__dropdown-menu" ]
                [ li []
                    [ a [ href (Route.toPath CostTransparency), class "app-nav__dropdown-link" ]
                        [ text "Costs" ]
                    ]
                ]
            ]
        , nav [ class "app-nav" ]
            [ ul [ class "app-nav__list" ]
                (case model.auth of
                    Nothing ->
                        [ navItem model.route Catalogue "Catalogue"
                        , navItem model.route Login "Sign In"
                        ]

                    Just auth ->
                        [ navItem model.route Library "Library"
                        , navItem model.route AntiLibrary "Antilibrary"
                        , navItem model.route WishList "Wish List"
                        , navItem model.route ReadingPile "Reading Pile"
                        , navItem model.route LookingForHome "Looking for a Home"
                        , navDropdown model.route
                            Catalogue
                            "Catalogue"
                            [ ( Search, "Search" )
                            , ( Upload, "Add Book" )
                            ]
                        , li
                            [ class
                                (if isSettingsRoute model.route then
                                    "app-nav__item app-nav__item--active app-nav__dropdown"

                                 else
                                    "app-nav__item app-nav__dropdown"
                                )
                            ]
                            [ Html.map UserMenuMsg
                                (UserMenu.view auth.user model.userMenu)
                            ]
                        ]
                )
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


navDropdown : Route -> Route -> String -> List ( Route, String ) -> Html Msg
navDropdown currentRoute primaryRoute primaryLabel subItems =
    let
        isActive =
            (currentRoute == primaryRoute)
                || List.any (\( r, _ ) -> currentRoute == r) subItems

        activeClass =
            if isActive then
                "app-nav__item app-nav__item--active app-nav__dropdown"

            else
                "app-nav__item app-nav__dropdown"
    in
    li [ class activeClass ]
        [ a [ href (Route.toPath primaryRoute), class "app-nav__link" ]
            [ text primaryLabel ]
        , ul [ class "app-nav__dropdown-menu" ]
            (List.map
                (\( route, label ) ->
                    li []
                        [ a [ href (Route.toPath route), class "app-nav__dropdown-link" ]
                            [ text label ]
                        ]
                )
                subItems
            )
        ]


viewPage : Model -> Html Msg
viewPage model =
    case model.page of
        PageHome ->
            viewHome

        PageLogin subModel ->
            Html.map LoginMsg (Login.view subModel)

        PageBookshelf subModel ->
            Html.map BookshelfMsg (Bookshelf.view subModel)

        PageReadingPile subModel ->
            Html.map ReadingPileMsg (ReadingPile.view subModel)

        PageLookingForHome subModel ->
            Html.map LookingForHomeMsg (LookingForHome.view subModel)

        PageBookDetail subModel ->
            Html.map BookDetailMsg (BookDetail.view subModel)

        PageUpload subModel ->
            Html.map UploadMsg (Upload.view subModel (Maybe.map .token model.auth))

        PageSearch subModel ->
            Html.map SearchMsg (Search.view subModel)

        PageSettingsConsent subModel ->
            viewSettingsHub model.route
                (Html.map ConsentMsg (Consent.view subModel))

        PageSettingsAgeVerification subModel ->
            viewSettingsHub model.route
                (Html.map AgeVerificationMsg (AgeVerification.view subModel))

        PageSettingsProfile subModel ->
            viewSettingsHub model.route
                (Html.map ProfileMsg (Profile.view subModel))

        PageSettingsPassword subModel ->
            viewSettingsHub model.route
                (Html.map PasswordMsg (Password.view subModel))

        PageSettingsNotifications subModel ->
            viewSettingsHub model.route
                (Html.map NotificationsMsg (Notifications.view subModel))

        PageCostTransparency subModel ->
            Html.map CostTransparencyMsg (CostTransparency.view subModel)

        PageCatalogue subModel ->
            Html.map CatalogueMsg (Catalogue.view subModel)

        PageConfirmEmail status ->
            viewConfirmEmail status

        PageNotFound ->
            viewNotFound


viewSettingsHub : Route -> Html Msg -> Html Msg
viewSettingsHub currentRoute content =
    Settings.view
        { currentRoute = currentRoute
        , content = content
        , onMobileNavChange = SettingsMobileNavChanged
        }


viewOverlay : Model -> Html Msg
viewOverlay model =
    case model.bookDetailOverlay of
        Just overlay ->
            Html.map OverlayBookDetailMsg (BookDetail.overlayView overlay.detail)

        Nothing ->
            text ""


viewHome : Html Msg
viewHome =
    div [ class "page page--home" ]
        [ h1 [ class "home__title" ] [ text "The Stacks" ]
        , p [ class "home__subtitle" ]
            [ text "Your personal collection, beautifully organised." ]
        , div [ class "home__actions" ]
            [ a [ href (Route.toPath AntiLibrary), class "btn btn--primary" ]
                [ text "View Antilibrary" ]
            , a [ href (Route.toPath Upload), class "btn btn--secondary" ]
                [ text "Add a Book" ]
            ]
        ]


viewConfirmEmail : ConfirmStatus -> Html Msg
viewConfirmEmail status =
    case status of
        EmailConfirmed ->
            div [ class "page page--confirm-email" ]
                [ h1 [] [ text "Email confirmed" ]
                , p [] [ text "Your email address has been verified. You can now use The Stacks." ]
                , a [ href (Route.toPath Login), class "btn btn--primary" ] [ text "Sign in" ]
                ]

        EmailConfirmFailed ->
            div [ class "page page--confirm-email page--confirm-email--error" ]
                [ h1 [] [ text "Confirmation failed" ]
                , p [] [ text "This link has expired or is no longer valid. Please register again to receive a new confirmation email." ]
                , a [ href "/", class "btn btn--primary" ] [ text "Go home" ]
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
