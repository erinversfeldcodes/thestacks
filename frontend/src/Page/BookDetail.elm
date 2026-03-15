module Page.BookDetail exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api
import Components.AgeGate exposing (ageGate)
import Components.FormatPicker exposing (formatPicker)
import Components.RemoveBookModal exposing (removeBookModal)
import Components.ShelfMover exposing (shelfMover)
import Html exposing (Html, button, div, h1, h2, h3, img, p, section, span, text)
import Html.Attributes exposing (alt, class, src)
import Html.Events exposing (onClick)
import Http
import Navigation.Route as Route exposing (Route)
import Types.Book exposing (Book, authorName)
import Types.Placement exposing (Format, Placement)
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { book : RemoteData Http.Error Book
    , placement : Maybe Placement
    , bookshelfMoverOpen : Bool
    , removeModalOpen : Bool
    , formatPickerOpen : Bool
    , selectedBookshelf : String -- DEFERRED: Replace with BookshelfName union type when ShelfMover and Api.moveBook are refactored. See Issue #030 item #6.
    , selectedFormats : List Format
    , moveState : RemoteData Http.Error ()
    , removeState : RemoteData Http.Error ()
    , previousRoute : Maybe Route
    , showAgeGate : Bool
    , entryAnimationActive : Bool
    }


type OutMsg
    = NoOut
    | NavigateTo Route


type Msg
    = BookLoaded (Result Http.Error Book)
    | OpenBookshelfMover
    | CloseBookshelfMover
    | SelectBookshelf String
    | ConfirmMove
    | MoveCompleted (Result Http.Error ())
    | OpenRemoveModal
    | CloseRemoveModal
    | ConfirmRemove
    | RemoveCompleted (Result Http.Error ())
    | ToggleFormat Format
    | VerifyAge
    | DismissAgeGate


init : String -> Maybe String -> Maybe Route -> ( Model, Cmd Msg )
init bookId maybeToken maybePreviousRoute =
    let
        cmd =
            case maybeToken of
                Just token ->
                    Api.getBook bookId token BookLoaded

                Nothing ->
                    Cmd.none
    in
    ( { book = Loading
      , placement = Nothing
      , bookshelfMoverOpen = False
      , removeModalOpen = False
      , formatPickerOpen = False
      , selectedBookshelf = "library"
      , selectedFormats = []
      , moveState = NotAsked
      , removeState = NotAsked
      , previousRoute = maybePreviousRoute
      , showAgeGate = False
      , entryAnimationActive = True
      }
    , cmd
    )


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        BookLoaded result ->
            case result of
                Ok book ->
                    ( { model | book = Success book }, Cmd.none, NoOut )

                Err (Http.BadStatus 403) ->
                    ( { model | book = Failure (Http.BadStatus 403), showAgeGate = True }, Cmd.none, NoOut )

                Err err ->
                    ( { model | book = Failure err }, Cmd.none, NoOut )

        VerifyAge ->
            ( model, Cmd.none, NavigateTo Route.SettingsAgeVerification )

        DismissAgeGate ->
            ( { model | showAgeGate = False }, Cmd.none, NoOut )

        OpenBookshelfMover ->
            ( { model | bookshelfMoverOpen = True }, Cmd.none, NoOut )

        CloseBookshelfMover ->
            ( { model | bookshelfMoverOpen = False }, Cmd.none, NoOut )

        SelectBookshelf bookshelf ->
            ( { model | selectedBookshelf = bookshelf }, Cmd.none, NoOut )

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
                    ( { model | moveState = Success () }, Cmd.none, NoOut )

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
            -- DEFERRED: Format toggles are display-only for now. Backend persistence
            -- via PUT /api/placements/:id/formats will be added when the placement
            -- format API is wired up. See Issue #030 review feedback item #5.
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
        [ viewHero model book
        , viewAboutSection book
        , viewReviewsSection
        , viewPricesSection
        , viewAuthorSection book
        , viewWritingSection
        , viewShelfActions model
        , viewDangerZone model
        ]


viewHero : Model -> Book -> Html Msg
viewHero model book =
    section [ class "book-detail__hero" ]
        [ div [ class "book-detail__cover-frame" ]
            [ div [ class "book-detail__cover" ]
                [ case book.coverImageUrl of
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
            [ h1 [ class "book-detail__title" ] [ text book.title ]
            , h2 [ class "book-detail__author" ] [ text (authorName book) ]
            , div [ class "book-detail__meta-details" ]
                [ case book.publicationYear of
                    Just year ->
                        span [ class "book-detail__meta-item" ]
                            [ text (String.fromInt year) ]

                    Nothing ->
                        text ""
                , case book.publisher of
                    Just publisher ->
                        span [ class "book-detail__meta-item" ]
                            [ text publisher ]

                    Nothing ->
                        text ""
                , case book.pageCount of
                    Just pages ->
                        span [ class "book-detail__meta-item" ]
                            [ text (String.fromInt pages ++ " pages") ]

                    Nothing ->
                        text ""
                ]
            , p [ class "book-detail__isbn" ] [ text ("ISBN " ++ book.isbn) ]
            , viewFormats model
            ]
        ]


viewFormats : Model -> Html Msg
viewFormats model =
    div [ class "book-detail__formats" ]
        [ formatPicker
            { selected = model.selectedFormats
            , onToggle = ToggleFormat
            }
        ]


viewAboutSection : Book -> Html Msg
viewAboutSection book =
    section [ class "book-detail__section book-detail__about" ]
        [ h3 [ class "book-detail__section-title" ] [ text "About" ]
        , div [ class "book-detail__about-body" ]
            [ case book.description of
                Just desc ->
                    p [ class "book-detail__about-text" ] [ text desc ]

                Nothing ->
                    p [ class "book-detail__about-text book-detail__about-text--empty" ]
                        [ text "No synopsis available yet." ]
            ]
        ]


viewReviewsSection : Html Msg
viewReviewsSection =
    section [ class "book-detail__section book-detail__reviews" ]
        [ h3 [ class "book-detail__section-title" ] [ text "What People Think" ]
        , div [ class "book-detail__reviews-grid" ]
            [ viewReviewSource "GoodReads" "goodreads"
            , viewReviewSource "Storygraph" "storygraph"
            , viewReviewSource "Reddit" "reddit"
            ]
        ]


viewReviewSource : String -> String -> Html Msg
viewReviewSource sourceName sourceClass =
    div [ class ("book-detail__review-card book-detail__review-card--" ++ sourceClass) ]
        [ div [ class "book-detail__review-header" ]
            [ span [ class "book-detail__review-source" ] [ text sourceName ]
            ]
        , div [ class "book-detail__review-body" ]
            [ p [ class "stub-notice" ] [ text "Sentiment data coming soon" ]
            ]
        ]


viewPricesSection : Html Msg
viewPricesSection =
    section [ class "book-detail__section book-detail__prices" ]
        [ h3 [ class "book-detail__section-title" ] [ text "Where to Buy (ZAR)" ]
        , div [ class "book-detail__prices-grid" ]
            [ p [ class "stub-notice" ]
                [ text "Bookshop price comparison coming soon" ]
            ]
        ]


viewAuthorSection : Book -> Html Msg
viewAuthorSection book =
    case book.author of
        Just author ->
            section [ class "book-detail__section book-detail__author-card" ]
                [ h3 [ class "book-detail__section-title" ] [ text "The Author" ]
                , div [ class "book-detail__author-info" ]
                    [ div [ class "book-detail__author-avatar" ]
                        [ span [ class "book-detail__author-initial" ]
                            [ text (String.left 1 author.name) ]
                        ]
                    , div [ class "book-detail__author-details" ]
                        [ p [ class "book-detail__author-name" ] [ text author.name ]
                        , case author.bio of
                            Just bio ->
                                p [ class "book-detail__author-bio" ] [ text bio ]

                            Nothing ->
                                text ""
                        ]
                    ]
                ]

        Nothing ->
            text ""


viewWritingSection : Html Msg
viewWritingSection =
    section [ class "book-detail__section book-detail__writing" ]
        [ h3 [ class "book-detail__section-title" ] [ text "My Writing" ]
        , div [ class "book-detail__writing-body" ]
            [ p [ class "stub-notice" ]
                [ text "Link your blog posts about this book" ]
            , button [ class "btn btn--secondary btn--sm" ]
                [ text "Add Post" ]
            ]
        ]


viewShelfActions : Model -> Html Msg
viewShelfActions model =
    section [ class "book-detail__section book-detail__shelf-actions" ]
        [ h3 [ class "book-detail__section-title" ] [ text "Move to Shelf" ]
        , if model.bookshelfMoverOpen then
            div []
                [ shelfMover
                    { currentBookshelf = model.selectedBookshelf
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
            [ text "Remove from Bookshelf" ]
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
