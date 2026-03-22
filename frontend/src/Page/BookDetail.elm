module Page.BookDetail exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , overlayView
    , update
    , view
    )

import Api
import Components.AgeGate exposing (ageGate)
import Components.AuthorCard as AuthorCard
import Components.FormatPicker exposing (formatPicker)
import Components.PriceInfo as PriceInfo
import Components.RemoveBookModal exposing (removeBookModal)
import Components.ReviewSummary as ReviewSummary
import Components.ShelfMover exposing (shelfMover)
import Html exposing (Html, a, button, div, h1, h2, h3, img, option, p, section, select, span, text)
import Html.Attributes exposing (alt, attribute, class, href, id, selected, src, style, tabindex, value)
import Html.Events exposing (onClick, onInput)
import Http
import Navigation.Route as Route exposing (Route)
import Types.Book exposing (Book, Edition, authorName)
import Types.Placement exposing (Format, Placement)
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { book : RemoteData Http.Error Book
    , placement : Maybe Placement
    , bookshelfMoverOpen : Bool
    , removeModalOpen : Bool
    , formatPickerOpen : Bool
    , currentBookshelf : String
    , selectedBookshelf : String
    , selectedFormats : List Format
    , moveState : RemoteData Http.Error ()
    , removeState : RemoteData Http.Error ()
    , selectedEdition : Maybe Edition
    , previousRoute : Maybe Route
    , showAgeGate : Bool
    , entryAnimationActive : Bool
    , isAuthenticated : Bool
    }


type OutMsg
    = NoOut
    | NavigateTo Route
    | RequestCloseOverlay


type Msg
    = BookLoaded (Result Http.Error Api.BookDetailResponse)
    | OpenBookshelfMover
    | CloseBookshelfMover
    | SelectBookshelf String
    | ConfirmMove
    | MoveCompleted (Result Http.Error ())
    | ConfirmPlace
    | PlaceCompleted String (Result Http.Error Placement)
    | OpenRemoveModal
    | CloseRemoveModal
    | ConfirmRemove
    | RemoveCompleted (Result Http.Error ())
    | ToggleFormat Format
    | EditionSelected String
    | VerifyAge
    | DismissAgeGate
    | CloseOverlay


init : String -> Maybe String -> Maybe Route -> ( Model, Cmd Msg )
init bookId maybeToken maybePreviousRoute =
    let
        cmd =
            Api.getBook bookId maybeToken BookLoaded
    in
    ( { book = Loading
      , placement = Nothing
      , bookshelfMoverOpen = False
      , removeModalOpen = False
      , formatPickerOpen = False
      , currentBookshelf = routeToBookshelf maybePreviousRoute
      , selectedBookshelf = firstAvailableBookshelf (routeToBookshelf maybePreviousRoute)
      , selectedFormats = []
      , moveState = NotAsked
      , removeState = NotAsked
      , selectedEdition = Nothing
      , previousRoute = maybePreviousRoute
      , showAgeGate = False
      , entryAnimationActive = True
      , isAuthenticated = maybeToken /= Nothing
      }
    , cmd
    )


routeToBookshelf : Maybe Route -> String
routeToBookshelf maybeRoute =
    case maybeRoute of
        Just Route.Library ->
            "library"

        Just Route.AntiLibrary ->
            "antilibrary"

        Just Route.WishList ->
            "wishlist"

        Just Route.ReadingPile ->
            "reading_pile"

        Just Route.LookingForHome ->
            "looking_for_home"

        _ ->
            ""


firstAvailableBookshelf : String -> String
firstAvailableBookshelf current =
    let
        all =
            [ "library", "antilibrary", "wishlist", "reading_pile", "looking_for_home" ]
    in
    List.filter (\s -> s /= current) all
        |> List.head
        |> Maybe.withDefault "antilibrary"


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        BookLoaded result ->
            case result of
                Ok response ->
                    let
                        bookshelf =
                            response.placement
                                |> Maybe.andThen .bookshelfName
                                |> Maybe.withDefault (routeToBookshelf model.previousRoute)

                        formats =
                            response.placement
                                |> Maybe.map .formats
                                |> Maybe.withDefault []
                    in
                    ( { model
                        | book = Success response.book
                        , placement = response.placement
                        , currentBookshelf = bookshelf
                        , selectedBookshelf = firstAvailableBookshelf bookshelf
                        , selectedFormats = formats
                        , selectedEdition = response.book.primaryEdition
                      }
                    , Cmd.none
                    , NoOut
                    )

                Err (Http.BadStatus 403) ->
                    ( { model | book = Failure (Http.BadStatus 403), showAgeGate = True }, Cmd.none, NoOut )

                Err err ->
                    ( { model | book = Failure err }, Cmd.none, NoOut )

        VerifyAge ->
            ( model, Cmd.none, NavigateTo Route.SettingsAgeVerification )

        DismissAgeGate ->
            ( { model | showAgeGate = False }, Cmd.none, NoOut )

        CloseOverlay ->
            ( model, Cmd.none, RequestCloseOverlay )

        OpenBookshelfMover ->
            ( { model | bookshelfMoverOpen = True }, Cmd.none, NoOut )

        CloseBookshelfMover ->
            ( { model | bookshelfMoverOpen = False }, Cmd.none, NoOut )

        SelectBookshelf bookshelf ->
            ( { model | selectedBookshelf = bookshelf }, Cmd.none, NoOut )

        EditionSelected editionId ->
            case model.book of
                Success book ->
                    let
                        found =
                            List.filter (\e -> e.id == editionId) book.editions
                                |> List.head
                    in
                    ( { model | selectedEdition = found }, Cmd.none, NoOut )

                _ ->
                    ( model, Cmd.none, NoOut )

        ConfirmMove ->
            case ( model.placement, maybeToken ) of
                ( Just placement, Just token ) ->
                    ( { model | bookshelfMoverOpen = False, moveState = Loading }
                    , Api.moveBook placement.id model.selectedBookshelf token MoveCompleted
                    , NoOut
                    )

                _ ->
                    ( model, Cmd.none, NoOut )

        MoveCompleted result ->
            case result of
                Ok _ ->
                    let
                        newBookshelf =
                            model.selectedBookshelf

                        updatedPlacement =
                            model.placement
                                |> Maybe.map (\p -> { p | bookshelfName = Just newBookshelf })
                    in
                    ( { model
                        | moveState = Success ()
                        , currentBookshelf = newBookshelf
                        , selectedBookshelf = firstAvailableBookshelf newBookshelf
                        , placement = updatedPlacement
                        , bookshelfMoverOpen = False
                      }
                    , Cmd.none
                    , NoOut
                    )

                Err err ->
                    ( { model | moveState = Failure err }, Cmd.none, NoOut )

        ConfirmPlace ->
            case ( model.book, maybeToken ) of
                ( Success book, Just token ) ->
                    ( { model | bookshelfMoverOpen = False, moveState = Loading }
                    , Api.placeBook model.selectedBookshelf book.id token (PlaceCompleted model.selectedBookshelf)
                    , NoOut
                    )

                _ ->
                    ( model, Cmd.none, NoOut )

        PlaceCompleted shelfName result ->
            case result of
                Ok placement ->
                    ( { model
                        | moveState = Success ()
                        , placement = Just placement
                        , currentBookshelf = shelfName
                        , selectedBookshelf = firstAvailableBookshelf shelfName
                        , bookshelfMoverOpen = False
                      }
                    , Cmd.none
                    , NoOut
                    )

                Err err ->
                    ( { model | moveState = Failure err }, Cmd.none, NoOut )

        OpenRemoveModal ->
            ( { model | removeModalOpen = True }, Cmd.none, NoOut )

        CloseRemoveModal ->
            ( { model | removeModalOpen = False }, Cmd.none, NoOut )

        ConfirmRemove ->
            case ( model.placement, maybeToken ) of
                ( Just placement, Just token ) ->
                    ( { model | removeModalOpen = False, removeState = Loading }
                    , Api.removeBook placement.id token RemoveCompleted
                    , NoOut
                    )

                _ ->
                    ( model, Cmd.none, NoOut )

        RemoveCompleted result ->
            case result of
                Ok _ ->
                    ( { model | removeState = Success () }
                    , Cmd.none
                    , NavigateTo (Maybe.withDefault Route.Library model.previousRoute)
                    )

                Err err ->
                    ( { model | removeState = Failure err }, Cmd.none, NoOut )

        ToggleFormat format ->
            let
                newFormats =
                    if List.member format model.selectedFormats then
                        List.filter (\f -> f /= format) model.selectedFormats

                    else
                        format :: model.selectedFormats
            in
            ( { model | selectedFormats = newFormats }, Cmd.none, NoOut )


view : Model -> Html Msg
view model =
    let
        animationClass =
            if model.entryAnimationActive then
                " book-detail-enter"

            else
                ""
    in
    div [ class ("page page--book-detail" ++ animationClass) ]
        [ if model.showAgeGate then
            ageGate
                { onVerify = VerifyAge
                , onDismiss = DismissAgeGate
                }

          else
            div [ class "book-detail__parchment" ]
                [ case model.book of
                    NotAsked ->
                        text ""

                    Loading ->
                        div [ class "loading" ] [ text "Loading book..." ]

                    Failure _ ->
                        p [ class "error" ] [ text "Could not load this book. Please try again." ]

                    Success book ->
                        viewBook model book
                , if model.removeModalOpen then
                    case model.book of
                        Success book ->
                            removeBookModal
                                { bookTitle = book.title
                                , onConfirm = ConfirmRemove
                                , onCancel = CloseRemoveModal
                                }

                        _ ->
                            text ""

                  else
                    text ""
                ]
        ]


viewBook : Model -> Book -> Html Msg
viewBook model book =
    div [ class "book-detail" ]
        ([ viewHero model book
         , viewAboutSection book
         , viewReviewsSection
         , viewPricesSection
         , viewAuthorSection book
         , viewWritingSection
         ]
            ++ (case ( model.placement, model.isAuthenticated ) of
                    ( Just _, _ ) ->
                        [ viewFormatsOnShelf model
                        , viewShelfActions model
                        , viewDangerZone model
                        ]

                    ( Nothing, True ) ->
                        [ viewAddToCollection model ]

                    ( Nothing, False ) ->
                        [ viewSignupPrompt ]
               )
        )


{-| Get the edition to display in the hero — either the user-selected edition
or the primary edition.
-}
displayEdition : Model -> Book -> Maybe Edition
displayEdition model book =
    case model.selectedEdition of
        Just ed ->
            Just ed

        Nothing ->
            book.primaryEdition


viewHero : Model -> Book -> Html Msg
viewHero model book =
    let
        edition =
            displayEdition model book
    in
    section [ class "book-detail__hero", attribute "role" "region", attribute "aria-labelledby" "section-hero" ]
        [ div [ class "book-detail__cover-frame" ]
            [ div [ class "book-detail__cover" ]
                [ case Maybe.andThen .coverImageUrl edition of
                    Just url ->
                        img
                            [ src url
                            , alt ("Cover of " ++ book.title)
                            , class "book-detail__cover-img"
                            ]
                            []

                    Nothing ->
                        div [ class "book-detail__cover-placeholder" ]
                            [ span [ class "book-detail__cover-placeholder-text" ]
                                [ text (String.left 1 book.title) ]
                            ]
                ]
            ]
        , div [ class "book-detail__meta" ]
            [ h1 [ class "book-detail__title", id "section-hero" ] [ text book.title ]
            , h2 [ class "book-detail__author" ] [ text (authorName book) ]
            , viewEditionSelector book model.selectedEdition
            , viewEditionDetails edition
            , viewRating model
            ]
        ]


viewRating : Model -> Html Msg
viewRating model =
    case model.placement of
        Just placement ->
            case placement.personalRating of
                Just n ->
                    div [ class "book-detail__rating" ]
                        [ text ("Your rating: " ++ String.fromInt n ++ "/5") ]

                Nothing ->
                    div [ class "book-detail__rating book-detail__rating--empty" ]
                        [ text "Not yet rated" ]

        Nothing ->
            div [ class "book-detail__rating book-detail__rating--empty" ]
                [ text "Not yet rated" ]


{-| Edition selector dropdown — appears below the author name.
Only renders if there are multiple editions.
-}
viewEditionSelector : Book -> Maybe Edition -> Html Msg
viewEditionSelector book selectedEdition =
    if List.length book.editions <= 1 then
        text ""

    else
        div [ class "book-detail__edition-selector" ]
            [ select
                [ class "book-detail__edition-select"
                , onInput EditionSelected
                ]
                (List.map
                    (\ed ->
                        let
                            label =
                                case ed.formatLabel of
                                    Just fl ->
                                        fl ++ " — " ++ ed.isbn

                                    Nothing ->
                                        ed.isbn
                        in
                        option
                            [ value ed.id
                            , selected (selectedEdition == Just ed)
                            ]
                            [ text label ]
                    )
                    book.editions
                )
            ]


{-| Edition-specific details: year, publisher, page count / narration length, ISBN.
Updates when the user selects a different edition from the dropdown.
-}
viewEditionDetails : Maybe Edition -> Html Msg
viewEditionDetails edition =
    div [ class "book-detail__meta-details" ]
        [ case Maybe.andThen .formatLabel edition of
            Just fl ->
                span [ class "book-detail__meta-item book-detail__meta-item--format" ]
                    [ text fl ]

            Nothing ->
                text ""
        , case Maybe.andThen .publicationYear edition of
            Just year ->
                span [ class "book-detail__meta-item" ]
                    [ text (String.fromInt year) ]

            Nothing ->
                text ""
        , case Maybe.andThen .publisher edition of
            Just publisher ->
                span [ class "book-detail__meta-item" ]
                    [ text publisher ]

            Nothing ->
                text ""
        , case Maybe.andThen .pageCount edition of
            Just pages ->
                span [ class "book-detail__meta-item" ]
                    [ text (String.fromInt pages ++ " pages") ]

            Nothing ->
                text ""
        , p [ class "book-detail__isbn" ]
            [ text
                ("ISBN "
                    ++ (edition |> Maybe.map .isbn |> Maybe.withDefault "—")
                )
            ]
        ]


{-| "Formats on my shelf" — only shown when the user has a placement.
Lets them toggle which formats (Physical, eBook, Audiobook) they own.
-}
viewFormatsOnShelf : Model -> Html Msg
viewFormatsOnShelf model =
    section [ class "book-detail__section book-detail__shelf-formats", attribute "role" "region", attribute "aria-labelledby" "section-formats" ]
        [ h3 [ class "book-detail__section-title", id "section-formats" ] [ text "Formats on My Shelf" ]
        , formatPicker
            { selected = model.selectedFormats
            , onToggle = ToggleFormat
            }
        ]


viewAboutSection : Book -> Html Msg
viewAboutSection book =
    section [ class "book-detail__section book-detail__about", attribute "role" "region", attribute "aria-labelledby" "section-about" ]
        [ h3 [ class "book-detail__section-title", id "section-about" ] [ text "About" ]
        , div [ class "book-detail__about-body" ]
            [ case book.description of
                Just desc ->
                    p [ class "book-detail__about-text" ] [ text desc ]

                Nothing ->
                    p [ class "book-detail__about-text book-detail__about-text--empty" ]
                        [ text "No synopsis available yet." ]
            ]
        ]


{-| Review summary section — delegates to the ReviewSummary component.
Currently passes NotAsked since the API does not yet provide per-book reviews.
-}
viewReviewsSection : Html Msg
viewReviewsSection =
    ReviewSummary.view NotAsked


{-| Price info section — delegates to the PriceInfo component.
Currently passes NotAsked since the API does not yet provide per-book prices.
-}
viewPricesSection : Html Msg
viewPricesSection =
    PriceInfo.view NotAsked


{-| Author card section — delegates to the AuthorCard component.
Passes the author from the book; enrichment is Nothing until the API is extended.
-}
viewAuthorSection : Book -> Html Msg
viewAuthorSection book =
    AuthorCard.view book.author Nothing


viewWritingSection : Html Msg
viewWritingSection =
    section [ class "book-detail__section book-detail__writing", attribute "role" "region", attribute "aria-labelledby" "section-writing" ]
        [ h3 [ class "book-detail__section-title", id "section-writing" ] [ text "My Writing" ]
        , div [ class "book-detail__writing-body" ]
            [ div [ class "book-detail__writing-list" ] []
            , p [ class "stub-notice" ]
                [ text "Link your blog posts about this book" ]
            , button [ class "btn btn--secondary btn--sm", attribute "aria-label" "Add a blog post about this book" ]
                [ text "Add Post" ]
            ]
        ]


viewSignupPrompt : Html Msg
viewSignupPrompt =
    section [ class "book-detail__section book-detail__signup-prompt" ]
        [ h3 [ class "book-detail__section-title" ]
            [ text "Create an account to start organising your collection" ]
        , a [ href "/login", class "btn btn--secondary" ]
            [ text "Sign In or Register" ]
        ]


viewAddToCollection : Model -> Html Msg
viewAddToCollection model =
    section [ class "book-detail__section book-detail__shelf-actions", attribute "role" "region", attribute "aria-labelledby" "section-add-to-collection" ]
        [ h3 [ class "book-detail__section-title", id "section-add-to-collection" ]
            [ text "Add to Collection" ]
        , if model.bookshelfMoverOpen then
            div []
                [ shelfMover
                    { currentBookshelf = ""
                    , selectedBookshelf = model.selectedBookshelf
                    , onSelectBookshelf = SelectBookshelf
                    , onMove = ConfirmPlace
                    }
                , button
                    [ class "btn btn--ghost btn--sm"
                    , onClick CloseBookshelfMover
                    ]
                    [ text "Cancel" ]
                ]

          else
            button [ class "btn btn--secondary", onClick OpenBookshelfMover ]
                [ text "Choose Bookshelf" ]
        , viewMoveState model.moveState
        ]


viewShelfActions : Model -> Html Msg
viewShelfActions model =
    section [ class "book-detail__section book-detail__shelf-actions", attribute "role" "region", attribute "aria-labelledby" "section-shelf-actions" ]
        [ h3 [ class "book-detail__section-title", id "section-shelf-actions" ]
            [ text
                (if String.isEmpty model.currentBookshelf then
                    "Move to Shelf"

                 else
                    "Move to Shelf from " ++ bookshelfLabel model.currentBookshelf
                )
            ]
        , if model.bookshelfMoverOpen then
            div []
                [ shelfMover
                    { currentBookshelf = model.currentBookshelf
                    , selectedBookshelf = model.selectedBookshelf
                    , onSelectBookshelf = SelectBookshelf
                    , onMove = ConfirmMove
                    }
                , button
                    [ class "btn btn--ghost btn--sm"
                    , onClick CloseBookshelfMover
                    ]
                    [ text "Cancel" ]
                ]

          else
            button [ class "btn btn--secondary", onClick OpenBookshelfMover ]
                [ text "Choose Bookshelf" ]
        , viewMoveState model.moveState
        ]


viewMoveState : RemoteData Http.Error () -> Html Msg
viewMoveState state =
    case state of
        NotAsked ->
            text ""

        Loading ->
            div [ class "book-detail__status book-detail__status--loading" ]
                [ text "Moving..." ]

        Success _ ->
            div [ class "book-detail__status book-detail__status--success" ]
                [ text "Moved successfully." ]

        Failure _ ->
            div [ class "book-detail__status book-detail__status--error" ]
                [ text "Failed to move book. Please try again." ]


viewDangerZone : Model -> Html Msg
viewDangerZone model =
    section [ class "book-detail__section book-detail__danger-zone" ]
        [ button [ class "btn btn--danger btn--sm", onClick OpenRemoveModal ]
            [ text "Remove from collection" ]
        , viewRemoveState model.removeState
        ]


viewRemoveState : RemoteData Http.Error () -> Html Msg
viewRemoveState state =
    case state of
        NotAsked ->
            text ""

        Loading ->
            div [ class "book-detail__status book-detail__status--loading" ]
                [ text "Removing..." ]

        Success _ ->
            text ""

        Failure _ ->
            div [ class "book-detail__status book-detail__status--error" ]
                [ text "Failed to remove book. Please try again." ]


bookshelfLabel : String -> String
bookshelfLabel name =
    case name of
        "library" ->
            "Library"

        "antilibrary" ->
            "Antilibrary"

        "wishlist" ->
            "Wish List"

        "reading_pile" ->
            "Reading Pile"

        "looking_for_home" ->
            "Looking for a Home"

        other ->
            other


{-| Render the book detail as a modal overlay.
Clicking the backdrop or the close button fires CloseOverlay.
Click on the card content is stopped from propagating to the backdrop.
-}
overlayView : Model -> Html Msg
overlayView model =
    let
        ariaLabel =
            case model.book of
                Success book ->
                    "Book details: " ++ book.title

                _ ->
                    "Book details"
    in
    div
        [ class "book-overlay"
        , style "position" "fixed"
        , style "top" "0"
        , style "left" "0"
        , style "width" "100vw"
        , style "height" "100vh"
        , style "z-index" "1000"
        , style "display" "flex"
        , style "align-items" "center"
        , style "justify-content" "center"
        ]
        [ div
            [ class "book-overlay__backdrop"
            , style "position" "absolute"
            , style "top" "0"
            , style "left" "0"
            , style "width" "100%"
            , style "height" "100%"
            , style "background" "rgba(10, 8, 6, 0.75)"
            , style "backdrop-filter" "blur(4px)"
            , style "-webkit-backdrop-filter" "blur(4px)"
            , onClick CloseOverlay
            ]
            []
        , div
            [ class "book-overlay__card"
            , attribute "role" "dialog"
            , attribute "aria-label" ariaLabel
            , attribute "aria-modal" "true"
            , tabindex -1
            , style "position" "relative"
            , style "z-index" "1001"
            , style "max-width" "900px"
            , style "width" "90vw"
            , style "max-height" "90vh"
            , style "overflow-y" "auto"
            , style "border-radius" "12px"
            , style "box-shadow" "0 8px 32px rgba(0,0,0,0.5)"
            ]
            [ button
                [ class "book-overlay__close"
                , id "book-overlay-close"
                , attribute "aria-label" "Close book details"
                , onClick CloseOverlay
                , style "position" "absolute"
                , style "top" "12px"
                , style "right" "12px"
                , style "z-index" "1002"
                , style "background" "rgba(0,0,0,0.4)"
                , style "color" "#e8dcc8"
                , style "border" "none"
                , style "border-radius" "50%"
                , style "width" "36px"
                , style "height" "36px"
                , style "font-size" "20px"
                , style "cursor" "pointer"
                , style "display" "flex"
                , style "align-items" "center"
                , style "justify-content" "center"
                ]
                [ text "×" ]
            , overlayContent model
            ]
        ]


{-| The inner content of the overlay — reuses the same view logic as the full page
but without the page wrapper classes.
-}
overlayContent : Model -> Html Msg
overlayContent model =
    if model.showAgeGate then
        ageGate
            { onVerify = VerifyAge
            , onDismiss = DismissAgeGate
            }

    else
        div [ class "book-detail__parchment" ]
            [ case model.book of
                NotAsked ->
                    text ""

                Loading ->
                    div [ class "loading", style "padding" "3rem", style "text-align" "center" ]
                        [ text "Loading book..." ]

                Failure _ ->
                    p [ class "error", style "padding" "3rem" ]
                        [ text "Could not load this book. Please try again." ]

                Success book ->
                    viewBook model book
            , if model.removeModalOpen then
                case model.book of
                    Success book ->
                        removeBookModal
                            { bookTitle = book.title
                            , onConfirm = ConfirmRemove
                            , onCancel = CloseRemoveModal
                            }

                    _ ->
                        text ""

              else
                text ""
            ]
