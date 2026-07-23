module Page.BookDetail exposing
    ( AvailabilityItem
    , Model
    , Msg(..)
    , OutMsg(..)
    , init
    , overlayView
    , update
    , view
    )

import Api
import Browser.Dom
import Components.AgeGate exposing (ageGate)
import Components.AuthorCard as AuthorCard
import Components.FormatPicker exposing (formatPicker)
import Components.PlacementCard as Card
import Components.PriceInfo as PriceInfo
import Components.RemoveBookModal exposing (removeBookModal)
import Components.ReviewSummary as ReviewSummary
import Components.ShelfMover exposing (shelfMover)
import Html exposing (Html, a, button, div, h1, h2, h3, img, label, li, option, p, section, select, span, text, ul)
import Html.Attributes exposing (alt, attribute, class, disabled, for, href, id, selected, src, style, tabindex, value)
import Html.Events exposing (on, onClick, onInput, targetValue)
import Http
import Json.Decode as Decode
import Navigation.Route as Route exposing (Route)
import Task
import Types.Book exposing (Book, Edition, authorName)
import Types.Placement exposing (Format, Placement, ReadingStatus(..), readingStatusToString)
import Types.RemoteData exposing (RemoteData(..))
import Types.Visibility as Visibility exposing (Visibility)
import Util.TestId exposing (testId)


type alias AvailabilityItem =
    { partnerName : String
    , priceCents : Int
    , condition : String
    , quantity : Int
    , isbn : String
    }


type alias Model =
    { book : RemoteData Http.Error Book
    , placement : Maybe Placement
    , bookshelfMoverOpen : Bool
    , removeModalOpen : Bool
    , formatPickerOpen : Bool
    , currentBookshelf : String
    , selectedBookshelf : String
    , selectedFormats : List Format
    , moveState : RemoteData Api.MoveError ()
    , removeState : RemoteData Http.Error ()
    , selectedEdition : Maybe Edition
    , previousRoute : Maybe Route

    -- Set True only on a backend 403 (age_verification_required). The server
    -- issues that 403 ONLY when age-gating is enforced (ADR-020: dark in prod →
    -- no 403 → the gate never shows), so this flag alone is the correct signal;
    -- no separate client-side age-gating flag is needed here.
    , showAgeGate : Bool
    , entryAnimationActive : Bool
    , isAuthenticated : Bool
    , availability : RemoteData Http.Error (List AvailabilityItem)
    , placementVisibility : Visibility
    , previousVisibility : Visibility
    , shelfCeiling : Visibility
    , visibilityState : RemoteData Http.Error ()

    -- Reading progress (US-1.6.6). The card is mounted only when the placement
    -- sits on a readable bookshelf (reading_pile, library).
    , progressCard : Maybe Card.Model
    , progressSaveState : RemoteData Api.ProgressError ()
    , finishedReadPrompt : Bool
    }


type OutMsg
    = NoOut
    | NavigateTo Route
    | RequestCloseOverlay
    | SessionExpired


type Msg
    = BookLoaded (Result Http.Error Api.BookDetailResponse)
    | OpenBookshelfMover
    | CloseBookshelfMover
    | SelectBookshelf String
    | ConfirmMove
    | MoveCompleted (Result Api.MoveError ())
    | ConfirmPlace
    | PlaceCompleted String (Result Api.PlaceError Placement)
    | OpenRemoveModal
    | CloseRemoveModal
    | ConfirmRemove
    | RemoveCompleted (Result Http.Error ())
    | ToggleFormat Format
    | EditionSelected String
    | DismissAgeGate
    | CloseOverlay
    | AvailabilityLoaded (Result Http.Error (List AvailabilityItem))
    | PlacementVisibilitySelected String
    | PlacementVisibilityUpdated (Result Http.Error String)
    | ProgressCardMsg Card.Msg
    | ProgressSaved (Result Api.ProgressError Api.Progress)
    | RecordReadRequested
    | FinishedReadDismissed
    | ProgressFocusReturned


init : String -> Maybe String -> Maybe Route -> ( Model, Cmd Msg )
init bookId maybeToken maybePreviousRoute =
    let
        bookCmd =
            Api.getBook bookId maybeToken BookLoaded

        availabilityCmd =
            fetchAvailability bookId maybeToken
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
      , availability = Loading

      -- Placement visibility defaults to "platform" (the DB default); the shelf
      -- ceiling defaults to the most permissive ("public") so nothing is greyed
      -- until the real values arrive with the placement payload.
      , placementVisibility = Visibility.Platform
      , previousVisibility = Visibility.Platform
      , shelfCeiling = Visibility.Public
      , visibilityState = NotAsked
      , progressCard = Nothing
      , progressSaveState = NotAsked
      , finishedReadPrompt = False
      }
    , Cmd.batch [ bookCmd, availabilityCmd ]
    )


fetchAvailability : String -> Maybe String -> Cmd Msg
fetchAvailability bookId maybeToken =
    let
        headers =
            case maybeToken of
                Just token ->
                    [ Http.header "Authorization" ("Bearer " ++ token) ]

                Nothing ->
                    []
    in
    Http.request
        { method = "GET"
        , headers = headers
        , url = "/api/books/" ++ bookId ++ "/availability"
        , body = Http.emptyBody
        , expect = Http.expectJson AvailabilityLoaded availabilityDecoder
        , timeout = Nothing
        , tracker = Nothing
        }


availabilityDecoder : Decode.Decoder (List AvailabilityItem)
availabilityDecoder =
    Decode.field "availability"
        (Decode.list
            (Decode.map5 AvailabilityItem
                (Decode.field "partner_name" Decode.string)
                (Decode.field "price_cents" Decode.int)
                (Decode.field "condition" Decode.string)
                (Decode.field "quantity" Decode.int)
                (Decode.field "isbn" Decode.string)
            )
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

                        placementVisibility =
                            response.placement
                                |> Maybe.andThen .visibility
                                |> Maybe.andThen Visibility.fromString
                                |> Maybe.withDefault Visibility.Platform

                        shelfCeiling =
                            response.bookshelfVisibility
                                |> Maybe.andThen Visibility.fromString
                                |> Maybe.withDefault Visibility.Public

                        progressCard =
                            case response.placement of
                                Just placement ->
                                    -- Reading progress is a readable-bookshelf
                                    -- affordance (Reading Pile, Library) only.
                                    -- Embed the loaded book so the card's
                                    -- progress line can show "/ {page count}"
                                    -- (the book-detail placement payload does
                                    -- not embed the book itself).
                                    if bookshelf == "reading_pile" || bookshelf == "library" then
                                        -- Hide the card's own title: the book
                                        -- identity is already the page context.
                                        Just (Card.hideTitle (Card.init { placement | book = Just response.book }))

                                    else
                                        Nothing

                                Nothing ->
                                    Nothing
                    in
                    ( { model
                        | book = Success response.book
                        , placement = response.placement
                        , currentBookshelf = bookshelf
                        , selectedBookshelf = firstAvailableBookshelf bookshelf
                        , selectedFormats = formats
                        , selectedEdition = response.book.primaryEdition
                        , placementVisibility = placementVisibility
                        , previousVisibility = placementVisibility
                        , shelfCeiling = shelfCeiling
                        , progressCard = progressCard
                      }
                    , Cmd.none
                    , NoOut
                    )

                Err (Http.BadStatus 403) ->
                    ( { model | book = Failure (Http.BadStatus 403), showAgeGate = True }, Cmd.none, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | book = Failure err }, Cmd.none, NoOut )

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

                Err Api.ReadingPileFull ->
                    ( { model | moveState = Failure Api.ReadingPileFull }, Cmd.none, NoOut )

                Err (Api.MoveHttpError err) ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | moveState = Failure (Api.MoveHttpError err) }, Cmd.none, NoOut )

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

                Err Api.PlaceReadingPileFull ->
                    -- #281: the place path can hit the same reading-pile cap the
                    -- move path does. Reuse the move path's ReadingPileFull so
                    -- viewMoveState renders the specific full-pile copy.
                    ( { model | moveState = Failure Api.ReadingPileFull }, Cmd.none, NoOut )

                Err (Api.PlaceHttpError err) ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        -- Wrap the transport error so the place path shares
                        -- moveState (and its generic copy) with the move path.
                        ( { model | moveState = Failure (Api.MoveHttpError err) }, Cmd.none, NoOut )

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
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | removeState = Failure err }, Cmd.none, NoOut )

        AvailabilityLoaded (Ok items) ->
            ( { model | availability = Success items }, Cmd.none, NoOut )

        AvailabilityLoaded (Err err) ->
            ( { model | availability = Failure err }, Cmd.none, NoOut )

        ToggleFormat format ->
            let
                newFormats =
                    if List.member format model.selectedFormats then
                        List.filter (\f -> f /= format) model.selectedFormats

                    else
                        format :: model.selectedFormats
            in
            ( { model | selectedFormats = newFormats }, Cmd.none, NoOut )

        PlacementVisibilitySelected raw ->
            case ( Visibility.fromString raw, model.placement, maybeToken ) of
                ( Just vis, Just placement, Just token ) ->
                    -- Ignore a new selection while a prior save is still in flight,
                    -- so previousVisibility retains the last CONFIRMED value for
                    -- rollback (a rapid double-change under latency would otherwise
                    -- capture an unconfirmed optimistic value).
                    if model.visibilityState == Loading then
                        ( model, Cmd.none, NoOut )
                        -- Guard client-side against the ceiling (mirrors the server
                        -- 422): a disabled option should never reach the wire.

                    else if Visibility.exceedsCeiling model.shelfCeiling vis then
                        ( model, Cmd.none, NoOut )

                    else
                        -- Optimistically show the new value, but remember the
                        -- prior one so a failed save can roll the select back.
                        ( { model
                            | placementVisibility = vis
                            , previousVisibility = model.placementVisibility
                            , visibilityState = Loading
                          }
                        , Api.updatePlacementVisibility placement.id (Visibility.toString vis) token PlacementVisibilityUpdated
                        , NoOut
                        )

                _ ->
                    ( model, Cmd.none, NoOut )

        PlacementVisibilityUpdated result ->
            case result of
                Ok visStr ->
                    let
                        confirmed =
                            Visibility.fromString visStr
                                |> Maybe.withDefault model.placementVisibility
                    in
                    ( { model
                        | visibilityState = Success ()
                        , placementVisibility = confirmed
                        , previousVisibility = confirmed
                      }
                    , Cmd.none
                    , NoOut
                    )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        -- Revert the optimistic change: the server rejected it,
                        -- so don't leave the rejected value shown in the select.
                        ( { model
                            | visibilityState = Failure err
                            , placementVisibility = model.previousVisibility
                          }
                        , Cmd.none
                        , NoOut
                        )

        ProgressCardMsg cardMsg ->
            case model.progressCard of
                Just card ->
                    let
                        ( newCard, out ) =
                            Card.update cardMsg card
                    in
                    case ( out, maybeToken ) of
                        ( Card.ProgressUpdateRequested, Just token ) ->
                            ( { model | progressCard = Just newCard, progressSaveState = Loading }
                            , Api.updateProgress newCard.placement.id
                                { readingStatus = readingStatusToString newCard.draftStatus
                                , currentPage = String.toInt newCard.draftPage
                                }
                                token
                                ProgressSaved
                            , NoOut
                            )

                        ( Card.EditClosed, _ ) ->
                            -- Form closed by Cancel: return focus to the badge.
                            ( { model | progressCard = Just newCard }, focusProgressBadge newCard, NoOut )

                        _ ->
                            ( { model | progressCard = Just newCard }, Cmd.none, NoOut )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        ProgressSaved result ->
            case result of
                Ok progress ->
                    ( { model
                        | placement = Maybe.map (\p -> Api.foldProgress p progress) model.placement

                        -- Fold from the CARD's placement (which carries the
                        -- embedded book) so the "/ {page count}" total survives.
                        -- Card.init closes the form on success.
                        , progressCard =
                            Maybe.map (\c -> Card.init (Api.foldProgress c.placement progress)) model.progressCard
                        , progressSaveState = Success ()

                        -- The "record this read?" bridge is a Reading Pile
                        -- affordance only — never offer a library→library move.
                        , finishedReadPrompt =
                            (progress.readingStatus == Just Completed && model.currentBookshelf == "reading_pile")
                                || model.finishedReadPrompt
                      }
                    , focusProgressBadgeFromModel model
                    , NoOut
                    )

                Err (Api.ProgressRequestFailed err) ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model
                            | progressCard = Maybe.map Card.stopSaving model.progressCard
                            , progressSaveState = Failure (Api.ProgressRequestFailed err)
                          }
                        , Cmd.none
                        , NoOut
                        )

                Err other ->
                    -- Keep the form open (draft preserved) so the reader can fix it.
                    ( { model
                        | progressCard = Maybe.map Card.stopSaving model.progressCard
                        , progressSaveState = Failure other
                      }
                    , Cmd.none
                    , NoOut
                    )

        ProgressFocusReturned ->
            ( model, Cmd.none, NoOut )

        RecordReadRequested ->
            case ( model.placement, maybeToken ) of
                ( Just placement, Just token ) ->
                    -- Reuse the existing move mechanism (US-1.6.3): send the
                    -- finished book to the Library. MoveCompleted folds the new
                    -- bookshelf name from selectedBookshelf, so pin it here.
                    ( { model | finishedReadPrompt = False, selectedBookshelf = "library", moveState = Loading }
                    , Api.moveBook placement.id "library" token MoveCompleted
                    , NoOut
                    )

                _ ->
                    ( model, Cmd.none, NoOut )

        FinishedReadDismissed ->
            ( { model | finishedReadPrompt = False }, Cmd.none, NoOut )


focusProgressBadge : Card.Model -> Cmd Msg
focusProgressBadge card =
    Browser.Dom.focus (Card.badgeDomId card.placement)
        |> Task.attempt (\_ -> ProgressFocusReturned)


focusProgressBadgeFromModel : Model -> Cmd Msg
focusProgressBadgeFromModel model =
    case model.progressCard of
        Just card ->
            focusProgressBadge card

        Nothing ->
            Cmd.none


{-| Fold the reading-progress fields returned by the API into the placement,
so the badge and progress line re-render in place.
-}
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
                { onDismiss = DismissAgeGate }

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
         , viewAvailabilitySection model
         , viewAuthorSection book
         , viewWritingSection
         ]
            ++ (case ( model.placement, model.isAuthenticated ) of
                    ( Just _, _ ) ->
                        [ viewProgressSection model
                        , viewFormatsOnShelf model
                        , viewVisibilityControl model
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
                            , testId "book-cover"
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
            [ h1 [ class "book-detail__title", testId "book-title", id "section-hero" ] [ text book.title ]
            , h2 [ class "book-detail__author", testId "book-author" ] [ text (authorName book) ]
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
                , testId "edition-selector"
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
        , p [ class "book-detail__isbn", testId "book-isbn" ]
            [ text
                ("ISBN "
                    ++ (edition |> Maybe.map .isbn |> Maybe.withDefault "—")
                )
            ]
        ]


{-| "Reading Progress" — the mounted PlacementCard (status badge + inline edit)
plus the save state and the "record this read?" bridge prompt. Rendered only
when the placement sits on a readable bookshelf (progressCard is Just).
-}
viewProgressSection : Model -> Html Msg
viewProgressSection model =
    case model.progressCard of
        Just card ->
            section
                [ class "book-detail__section book-detail__progress"
                , attribute "role" "region"
                , attribute "aria-labelledby" "section-progress"
                ]
                [ h3 [ class "book-detail__section-title", id "section-progress" ] [ text "Reading Progress" ]
                , Html.map ProgressCardMsg (Card.view card)
                , viewProgressSaveState model.progressSaveState
                , if model.finishedReadPrompt then
                    viewFinishedReadPrompt

                  else
                    text ""
                ]

        Nothing ->
            text ""


viewProgressSaveState : RemoteData Api.ProgressError () -> Html Msg
viewProgressSaveState state =
    case state of
        Failure err ->
            p
                [ class "book-detail__status book-detail__status--error"
                , attribute "role" "alert"
                , id "progress-error"
                , testId "progress-error"
                ]
                [ text (Api.progressErrorMessage err) ]

        _ ->
            text ""


viewFinishedReadPrompt : Html Msg
viewFinishedReadPrompt =
    div [ class "book-detail__finished-prompt", testId "finished-read-prompt" ]
        [ p [] [ text "Move to your Library and record this read?" ]
        , button
            [ class "btn btn--primary btn--sm"
            , onClick RecordReadRequested
            , testId "record-read-btn"
            ]
            [ text "Move to Library" ]
        , button
            [ class "btn btn--ghost btn--sm"
            , onClick FinishedReadDismissed
            ]
            [ text "Not now" ]
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


{-| "Who can see this book" — per-placement visibility override (US-10.2.2).
Only shown when the user owns a placement. Options that would make the placement
more visible than its parent shelf are greyed out, with an always-visible line of
helper text explaining the shelf ceiling, mirroring the server-side ceiling 422.
-}
viewVisibilityControl : Model -> Html Msg
viewVisibilityControl model =
    section
        [ class "book-detail__section book-detail__visibility"
        , attribute "role" "region"
        , attribute "aria-labelledby" "section-visibility"
        ]
        [ h3 [ class "book-detail__section-title", id "section-visibility" ]
            [ text "Who can see this book" ]
        , label
            [ class "book-detail__visibility-label"
            , for "placement-visibility-select"
            ]
            [ text "Visibility" ]
        , select
            [ class "book-detail__visibility-select"
            , id "placement-visibility-select"
            , testId "placement-visibility-select"
            , on "change" (Decode.map PlacementVisibilitySelected targetValue)
            ]
            (List.map (viewVisibilityOption model.placementVisibility) (Visibility.placementOptions model.shelfCeiling))
        , viewCeilingHelperText model.shelfCeiling
        , viewVisibilityState model.visibilityState
        ]


{-| Always-visible explanation of why some options are greyed out, shown only
when the shelf ceiling actually restricts something. Replaces the `title`
tooltip on disabled options, which browsers don't render.
-}
viewCeilingHelperText : Visibility -> Html Msg
viewCeilingHelperText ceiling =
    case Visibility.ceilingHelperText ceiling of
        Just helper ->
            p [ class "book-detail__visibility-help" ] [ text helper ]

        Nothing ->
            text ""


viewVisibilityOption : Visibility -> Visibility.PlacementOption -> Html Msg
viewVisibilityOption current opt =
    option
        [ value (Visibility.toString opt.visibility)
        , selected (opt.visibility == current)
        , disabled opt.disabled
        ]
        [ text opt.label ]


viewVisibilityState : RemoteData Http.Error () -> Html Msg
viewVisibilityState state =
    case state of
        NotAsked ->
            text ""

        Loading ->
            div [ class "book-detail__status book-detail__status--loading" ]
                [ text "Saving visibility…" ]

        Success _ ->
            div [ class "book-detail__status book-detail__status--success" ]
                [ text "Visibility saved." ]

        Failure _ ->
            div [ class "book-detail__status book-detail__status--error" ]
                [ text "We couldn't save that change. Please try again." ]


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


viewAvailabilitySection : Model -> Html Msg
viewAvailabilitySection model =
    case model.availability of
        Success (first :: rest) ->
            section [ class "book-detail__section book-detail__availability", attribute "role" "region", attribute "aria-labelledby" "section-availability" ]
                [ h3 [ class "book-detail__section-title", id "section-availability" ] [ text "Available at" ]
                , ul [ class "book-detail__availability-list" ]
                    (List.map viewAvailabilityRow (first :: rest))
                ]

        _ ->
            text ""


viewAvailabilityRow : AvailabilityItem -> Html Msg
viewAvailabilityRow item =
    li [ class "book-detail__availability-row" ]
        [ span [ class "book-detail__availability-partner" ] [ text item.partnerName ]
        , span [ class "book-detail__availability-condition" ] [ text item.condition ]
        , span [ class "book-detail__availability-price" ] [ text (formatPrice item.priceCents) ]
        ]


formatPrice : Int -> String
formatPrice cents =
    let
        major =
            cents // 100

        minor =
            modBy 100 cents

        minorStr =
            if minor < 10 then
                "0" ++ String.fromInt minor

            else
                String.fromInt minor
    in
    "R" ++ String.fromInt major ++ "." ++ minorStr


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


viewMoveState : RemoteData Api.MoveError () -> Html Msg
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

        Failure Api.ReadingPileFull ->
            -- #276: the write path rejected the move because the reading
            -- pile is at its 50-book cap. Distinct from a transport failure.
            div
                [ class "book-detail__status book-detail__status--error"
                , testId "reading-pile-full-msg"
                ]
                [ text "Your reading pile is full — finish or remove a book before adding another." ]

        Failure (Api.MoveHttpError _) ->
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
        , testId "book-overlay"
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
                , testId "book-overlay-close"
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
            { onDismiss = DismissAgeGate }

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
