module Page.BookDetail exposing
    ( AvailabilityItem
    , Model
    , Msg(..)
    , OutMsg(..)
    , availabilityDecoder
    , cardFocusId
    , firstFocusableId
    , init
    , lastFocusableId
    , overlayView
    , pricesDecoder
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
import Components.RemoveBookModal as RemoveBookModal exposing (removeBookModal)
import Components.ShelfMover exposing (shelfMover)
import Html exposing (Html, a, button, div, h1, h2, h3, img, label, li, option, p, section, select, span, text, ul)
import Html.Attributes exposing (alt, attribute, class, disabled, for, href, id, selected, src, style, tabindex, value)
import Html.Events exposing (on, onClick, onInput, preventDefaultOn, targetValue)
import Http
import Json.Decode as Decode
import Navigation.Route as Route exposing (Route)
import Task
import Types.Book exposing (Book, Edition, authorName, bookIsbn, displayTitle, isUnidentified)
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
    , placements : List Placement
    , removingPlacementId : Maybe String
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
    , authorEvents : RemoteData Http.Error (List Api.AuthorEvent)
    , showAgeGate : Bool
    , entryAnimationActive : Bool
    , isAuthenticated : Bool
    , availability : RemoteData Http.Error (List AvailabilityItem)
    , prices : RemoteData Http.Error PriceInfo.PriceData
    , placementVisibility : Visibility
    , previousVisibility : Visibility
    , shelfCeiling : Visibility
    , visibilityState : RemoteData Http.Error ()
    , progressCard : Maybe Card.Model
    , progressSaveState : RemoteData Api.ProgressError ()
    , finishedReadPrompt : Bool
    , undoableRemoval : Maybe { placementId : String, bookTitle : String }
    }


type OutMsg
    = NoOut
    | NavigateTo Route
    | RequestCloseOverlay
    | SessionExpired


type Msg
    = BookLoaded (Result Http.Error Api.BookDetailResponse)
    | GotAuthorEvents (Result Http.Error (List Api.AuthorEvent))
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
    | RemovePlacement String
    | PlacementRemoved String (Result Http.Error ())
    | ToggleFormat Format
    | EditionSelected String
    | DismissAgeGate
    | CloseOverlay
    | AvailabilityLoaded (Result Http.Error (List AvailabilityItem))
    | PricesLoaded (Result Http.Error PriceInfo.PriceData)
    | PlacementVisibilitySelected String
    | PlacementVisibilityUpdated (Result Http.Error String)
    | ProgressCardMsg Card.Msg
    | ProgressSaved (Result Api.ProgressError Api.Progress)
    | RecordReadRequested
    | FinishedReadDismissed
    | ProgressFocusReturned
    | EscapePressed
    | FocusWrapToFirst
    | FocusWrapToLast
    | FocusOn String
    | FocusWrapNoOp


init : String -> Maybe String -> Maybe Route -> ( Model, Cmd Msg )
init bookId maybeToken maybePreviousRoute =
    let
        bookCmd =
            Api.getBook bookId maybeToken BookLoaded

        availabilityCmd =
            fetchAvailability bookId maybeToken

        pricesCmd =
            fetchPrices bookId maybeToken
    in
    ( { book = Loading
      , placement = Nothing
      , placements = []
      , removingPlacementId = Nothing
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
      , authorEvents = NotAsked
      , showAgeGate = False
      , entryAnimationActive = True
      , isAuthenticated = maybeToken /= Nothing
      , availability = Loading
      , prices = Loading

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
      , undoableRemoval = Nothing
      }
    , Cmd.batch [ bookCmd, availabilityCmd, pricesCmd ]
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
        , timeout = Api.standardTimeout
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


fetchPrices : String -> Maybe String -> Cmd Msg
fetchPrices bookId maybeToken =
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
        , url = "/api/books/" ++ bookId ++ "/prices"
        , body = Http.emptyBody
        , expect = Http.expectJson PricesLoaded pricesDecoder
        , timeout = Api.standardTimeout
        , tracker = Nothing
        }


{-| One flat row per (edition, store), as the API returns it.

Grouping into editions happens here rather than server-side: it is a presentation
concern, and the flat shape is the honest wire format for what is stored.

-}
type alias PriceRow =
    { isbn : String
    , formatLabel : String
    , storeName : String
    , priceCents : Int
    , buyUrl : String
    , scrapedAt : String
    }


pricesDecoder : Decode.Decoder PriceInfo.PriceData
pricesDecoder =
    Decode.field "prices" (Decode.list priceRowDecoder)
        |> Decode.map groupPricesByEdition


priceRowDecoder : Decode.Decoder PriceRow
priceRowDecoder =
    Decode.map6 PriceRow
        (Decode.field "isbn" Decode.string)
        (Decode.oneOf
            [ Decode.field "format_label" Decode.string
            , Decode.succeed "Edition"
            ]
        )
        (Decode.oneOf
            [ Decode.field "store_name" Decode.string
            , Decode.succeed "Unknown store"
            ]
        )
        (Decode.field "price_cents" Decode.int)
        (Decode.oneOf [ Decode.field "url" Decode.string, Decode.succeed "" ])
        (Decode.oneOf [ Decode.field "scraped_at" Decode.string, Decode.succeed "" ])


groupPricesByEdition : List PriceRow -> PriceInfo.PriceData
groupPricesByEdition rows =
    { editions =
        rows
            |> List.map .isbn
            |> uniqueStrings
            |> List.map (editionPricesFor rows)
    , lastUpdated =
        rows |> List.map .scrapedAt |> List.maximum |> Maybe.withDefault ""
    }


editionPricesFor : List PriceRow -> String -> PriceInfo.EditionPrices
editionPricesFor rows isbn =
    let
        matching =
            List.filter (\row -> row.isbn == isbn) rows
    in
    { formatLabel =
        matching |> List.head |> Maybe.map .formatLabel |> Maybe.withDefault "Edition"
    , isbn = isbn
    , stores = matching |> List.map toStoreListing |> List.sortBy .priceZar
    }


toStoreListing : PriceRow -> PriceInfo.StoreListing
toStoreListing row =
    { storeName = row.storeName
    , priceZar = toFloat row.priceCents / 100
    , buyUrl = row.buyUrl
    , trend = ""
    }


uniqueStrings : List String -> List String
uniqueStrings items =
    List.foldr
        (\item acc ->
            if List.member item acc then
                acc

            else
                item :: acc
        )
        []
        items


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
                                |> Maybe.withDefault Visibility.Platform

                        shelfCeiling =
                            response.bookshelfVisibility
                                |> Maybe.andThen Visibility.fromString
                                |> Maybe.withDefault Visibility.Public

                        progressCard =
                            case response.placement of
                                Just placement ->
                                    if bookshelf == "reading_pile" || bookshelf == "library" then
                                        Just (Card.hideTitle (Card.init { placement | book = Just response.book }))

                                    else
                                        Nothing

                                Nothing ->
                                    Nothing
                    in
                    ( { model
                        | book = Success response.book
                        , authorEvents =
                            case response.book.author of
                                Just _ ->
                                    Loading

                                Nothing ->
                                    NotAsked
                        , placement = response.placement
                        , placements = response.placements
                        , removingPlacementId = Nothing
                        , currentBookshelf = bookshelf
                        , selectedBookshelf = firstAvailableBookshelf bookshelf
                        , selectedFormats = formats
                        , selectedEdition = response.book.primaryEdition
                        , placementVisibility = placementVisibility
                        , previousVisibility = placementVisibility
                        , shelfCeiling = shelfCeiling
                        , progressCard = progressCard
                      }
                    , case response.book.author of
                        Just author ->
                            Api.getAuthorEvents author.id GotAuthorEvents

                        Nothing ->
                            Cmd.none
                    , NoOut
                    )

                Err (Http.BadStatus 403) ->
                    ( { model | book = Failure (Http.BadStatus 403), showAgeGate = True }, Cmd.none, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | book = Failure err }, Cmd.none, NoOut )

        GotAuthorEvents result ->
            case result of
                Ok events ->
                    ( { model | authorEvents = Success events }, Cmd.none, NoOut )

                Err err ->
                    ( { model | authorEvents = Failure err }, Cmd.none, NoOut )

        DismissAgeGate ->
            ( { model | showAgeGate = False }, Cmd.none, NoOut )

        CloseOverlay ->
            ( model, Cmd.none, RequestCloseOverlay )

        EscapePressed ->
            if model.removeModalOpen then
                ( { model | removeModalOpen = False }, focusElement removeTriggerId, NoOut )

            else
                case model.progressCard of
                    Just card ->
                        if card.editing then
                            let
                                ( closedCard, _ ) =
                                    Card.update Card.CancelClicked card
                            in
                            ( { model | progressCard = Just closedCard }, focusProgressBadge closedCard, NoOut )

                        else
                            ( model, Cmd.none, RequestCloseOverlay )

                    Nothing ->
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
                    ( { model | moveState = Failure Api.ReadingPileFull }, Cmd.none, NoOut )

                Err (Api.PlaceHttpError err) ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | moveState = Failure (Api.MoveHttpError err) }, Cmd.none, NoOut )

        OpenRemoveModal ->
            ( { model | removeModalOpen = True }, focusElement RemoveBookModal.cancelButtonId, NoOut )

        CloseRemoveModal ->
            ( { model | removeModalOpen = False }, focusElement removeTriggerId, NoOut )

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
                    ( { model
                        | removeState = Success ()
                        , undoableRemoval = undoableRemovalFor model
                      }
                    , Cmd.none
                    , NavigateTo (Maybe.withDefault Route.Library model.previousRoute)
                    )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | removeState = Failure err }, Cmd.none, NoOut )

        RemovePlacement placementId ->
            case maybeToken of
                Just token ->
                    ( { model | removingPlacementId = Just placementId }
                    , Api.removeBook placementId token (PlacementRemoved placementId)
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        PlacementRemoved placementId result ->
            case result of
                Ok _ ->
                    let
                        remaining =
                            List.filter (\p -> p.id /= placementId) model.placements

                        primary =
                            case model.placement of
                                Just current ->
                                    if current.id == placementId then
                                        List.head remaining

                                    else
                                        Just current

                                Nothing ->
                                    List.head remaining
                    in
                    ( { model
                        | placements = remaining
                        , placement = primary
                        , removingPlacementId = Nothing
                        , currentBookshelf =
                            primary
                                |> Maybe.andThen .bookshelfName
                                |> Maybe.withDefault model.currentBookshelf
                      }
                    , Cmd.none
                    , NoOut
                    )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | removingPlacementId = Nothing, removeState = Failure err }
                        , Cmd.none
                        , NoOut
                        )

        AvailabilityLoaded (Ok items) ->
            ( { model | availability = Success items }, Cmd.none, NoOut )

        AvailabilityLoaded (Err err) ->
            ( { model | availability = Failure err }, Cmd.none, NoOut )

        PricesLoaded (Ok priceData) ->
            ( { model | prices = Success priceData }, Cmd.none, NoOut )

        PricesLoaded (Err err) ->
            ( { model | prices = Failure err }, Cmd.none, NoOut )

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
                    if model.visibilityState == Loading then
                        ( model, Cmd.none, NoOut )

                    else if Visibility.exceedsCeiling model.shelfCeiling vis then
                        ( model, Cmd.none, NoOut )

                    else
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
                        , progressCard =
                            Maybe.map (\c -> Card.init (Api.foldProgress c.placement progress)) model.progressCard
                        , progressSaveState = Success ()
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
                    ( { model | finishedReadPrompt = False, selectedBookshelf = "library", moveState = Loading }
                    , Api.moveBook placement.id "library" token MoveCompleted
                    , NoOut
                    )

                _ ->
                    ( model, Cmd.none, NoOut )

        FinishedReadDismissed ->
            ( { model | finishedReadPrompt = False }, Cmd.none, NoOut )

        FocusWrapToFirst ->
            ( model, focusElement firstFocusableId, NoOut )

        FocusWrapToLast ->
            ( model, focusElement lastFocusableId, NoOut )

        FocusOn elementId ->
            ( model, focusElement elementId, NoOut )

        FocusWrapNoOp ->
            ( model, Cmd.none, NoOut )


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


{-| The DOM id of the dialog card — the element focused when the overlay opens
(#295 item a; see `Main.openOverlay`). The card carries `tabindex -1` and the
`aria-label "Book details: {title}"`, so a screen reader announces the book on
open, and the first forward Tab moves to the close button (the card is out of
the tab order). It is deliberately NOT a focus-trap anchor: the trap still wraps
between the close button (first control) and the trailing sentinel (last).
-}
cardFocusId : String
cardFocusId =
    "book-overlay-card"


{-| The DOM id of the first focusable CONTROL in the overlay — the close button.
The focus trap wraps to this id when Tab falls off the trailing sentinel. (The
element focused on open is the dialog card, `cardFocusId`, not this control.)
-}
firstFocusableId : String
firstFocusableId =
    "book-overlay-close"


{-| The DOM id of the trailing focus sentinel — the last tab stop inside the
overlay card. Shift+Tab off the first control wraps here; forward Tab off it
wraps back to the first control. Anchoring "last" to a fixed sentinel keeps the
trap correct regardless of which content controls the overlay renders.
-}
lastFocusableId : String
lastFocusableId =
    "book-overlay-focus-sentinel"


{-| The DOM id of the "Remove from collection" button — the control that opens
the remove-confirmation dialog, and where focus returns when it closes.
-}
removeTriggerId : String
removeTriggerId =
    "book-detail-remove-trigger"


{-| What `Main` needs to offer "Removed — Undo" on the shelf the reader is about
to land on (#375).

`Nothing` when either half is missing, and both halves are load-bearing rather
than cosmetic: without the placement id there is no row to restore, and without
the title the toast would have to say "Removed a book", which is precisely the
sentence a reader who mis-clicked cannot check. An absent offer is honest; an
offer that cannot name what it would put back is not.

-}
undoableRemovalFor : Model -> Maybe { placementId : String, bookTitle : String }
undoableRemovalFor model =
    case ( model.placement, model.book ) of
        ( Just placement, Success book ) ->
            Just { placementId = placement.id, bookTitle = book.title }

        _ ->
            Nothing


{-| Move DOM focus to the given element id, discarding the (ignorable) result.
-}
focusElement : String -> Cmd Msg
focusElement elementId =
    Browser.Dom.focus elementId
        |> Task.attempt (\_ -> FocusWrapNoOp)


{-| Keydown decoder for the overlay card implementing the Tab focus trap.

It reads `key`, `shiftKey`, and the focused element's `target.id`, and only
`preventDefault`s (and emits a wrap message) at the two overlay boundaries:

  - forward Tab while on the trailing sentinel → wrap to the first control
  - Shift+Tab while on the first control → wrap to the trailing sentinel

Every other keydown fails the decoder, so native tab order is preserved for
all the controls in between and no `preventDefault` is applied.

-}
trapKeydownDecoder : Decode.Decoder ( Msg, Bool )
trapKeydownDecoder =
    Decode.map3 trapDecision
        (Decode.field "key" Decode.string)
        (Decode.field "shiftKey" Decode.bool)
        (Decode.at [ "target", "id" ] Decode.string)
        |> Decode.andThen identity


trapDecision : String -> Bool -> String -> Decode.Decoder ( Msg, Bool )
trapDecision key shiftKey targetId =
    if key /= "Tab" then
        Decode.fail "focus-trap: not a Tab keydown"

    else if not shiftKey && targetId == lastFocusableId then
        Decode.succeed ( FocusWrapToFirst, True )

    else if shiftKey && targetId == firstFocusableId then
        Decode.succeed ( FocusWrapToLast, True )

    else
        Decode.fail "focus-trap: natural tab order"


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
                                , onWrapToFirst = FocusOn RemoveBookModal.cancelButtonId
                                , onWrapToLast = FocusOn RemoveBookModal.confirmButtonId
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
         , viewPricesSection model
         , viewAvailabilitySection model
         , viewAuthorSection model book
         , viewWritingSection
         ]
            ++ (case ( model.placement, model.isAuthenticated ) of
                    ( Just _, _ ) ->
                        [ viewMultiShelfNotice model
                        , viewProgressSection model
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
            [ h1 [ class "book-detail__title", testId "book-title", id "section-hero" ]
                [ text (displayTitle book) ]
            , viewProvisionalNotice book
            , h2 [ class "book-detail__author", testId "book-author" ] [ text (authorName book) ]
            , viewEditionSelector book model.selectedEdition
            , viewEditionDetails edition
            , viewRating model
            ]
        ]


{-| The book's own page is where a reader lands when the ISBN-shaped title on
their shelf made no sense to them, so it is the page that owes them the
explanation (#344).

Informational only, and deliberately placed after the title rather than in front
of the page: everything below it — shelving, rating, notes, writing — stays
available, because a provisional book is a book the reader legitimately owns and
the ISBN gate legitimately passed. Only the lookup is outstanding.

Keyed off `isUnidentified`, not `isProvisional` (#370). This sentence says the
page cannot show a title, so it may only appear on a page that is not showing
one — which is the same predicate `displayTitle` withholds the title on. One
predicate for both is what makes the contradiction unreachable rather than
merely absent: there is no state in which the heading prints `book.title` and
this paragraph denies it.

-}
viewProvisionalNotice : Book -> Html Msg
viewProvisionalNotice book =
    if isUnidentified book then
        p
            [ class "book-detail__provisional"
            , testId "book-provisional-notice"
            , attribute "role" "status"
            ]
            [ text
                ("We have this book's barcode ("
                    ++ bookIsbn book
                    ++ ") but haven't matched it to a catalogue record yet, "
                    ++ "so we can't show its title or cover. It is still yours and still on your shelf."
                )
            ]

    else
        text ""


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


{-| The four bookshelves that make a book "in your collection twice".

Looking for a Home is deliberately absent: it is a marketplace state, not a
place you keep a book, so a Library book you are also offering to rehome is one
copy in one place — nothing to tidy up (owner ruling, 2026-07-30).

-}
collectionBookshelves : List String
collectionBookshelves =
    [ "library", "antilibrary", "reading_pile", "wishlist" ]


{-| The placements that count toward the multi-shelf notice: active placements
on the four collection bookshelves, in the order the server returned them
(oldest first).
-}
collectionPlacements : Model -> List Placement
collectionPlacements model =
    List.filter
        (\p ->
            case p.bookshelfName of
                Just name ->
                    List.member name collectionBookshelves

                Nothing ->
                    False
        )
        model.placements


{-| "This book is on two of your bookshelves" — the multi-shelf highlight
(#333).

Shown only when the book sits on 2+ of Library / Antilibrary / Reading Pile /
Wish List. The reader put it there, so the copy is a plain observation with a
way to act on it, not a warning: multi-shelf is a legal state and nothing here
blocks anything. Each shelf gets its OWN remove button, because "remove this
book" is ambiguous the moment there is more than one placement — the reader has
to be able to say _which_ copy goes.

-}
viewMultiShelfNotice : Model -> Html Msg
viewMultiShelfNotice model =
    let
        placements =
            collectionPlacements model
    in
    if List.length placements < 2 then
        text ""

    else
        section
            [ class "book-detail__multi-shelf"
            , testId "multi-shelf-notice"
            , attribute "role" "region"
            , attribute "aria-labelledby" "section-multi-shelf"
            ]
            [ h3
                [ class "book-detail__section-title"
                , id "section-multi-shelf"
                ]
                [ text
                    ("This one is on "
                        ++ String.fromInt (List.length placements)
                        ++ " of your bookshelves"
                    )
                ]
            , p [ class "book-detail__multi-shelf-note" ]
                [ text "Keep it that way if you meant to — or take it off the ones you didn't." ]
            , ul [ class "book-detail__multi-shelf-list" ]
                (List.map (viewMultiShelfRow model) placements)
            ]


viewMultiShelfRow : Model -> Placement -> Html Msg
viewMultiShelfRow model placement =
    let
        name =
            Maybe.withDefault "" placement.bookshelfName

        removing =
            model.removingPlacementId == Just placement.id
    in
    li
        [ class "book-detail__multi-shelf-item"
        , testId ("multi-shelf-item-" ++ name)
        ]
        [ span [ class "book-detail__multi-shelf-name" ] [ text (bookshelfLabel name) ]
        , button
            [ class "btn btn--ghost btn--sm book-detail__multi-shelf-remove"
            , testId ("multi-shelf-remove-" ++ name)
            , disabled removing
            , attribute "aria-label" ("Remove from your " ++ bookshelfLabel name ++ " shelf")
            , onClick (RemovePlacement placement.id)
            ]
            [ text
                (if removing then
                    "Removing…"

                 else
                    "Remove from here"
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


{-| Price info section — delegates to the PriceInfo component.
Currently passes NotAsked since the API does not yet provide per-book prices.
-}
viewPricesSection : Model -> Html Msg
viewPricesSection model =
    PriceInfo.view model.prices


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
RSS enrichment stays Nothing (its API is future work); events are live
(#321 item 4), passed only once fetched so the card's "coming soon" stub
remains the honest not-yet-asked state.
-}
viewAuthorSection : Model -> Book -> Html Msg
viewAuthorSection model book =
    AuthorCard.view book.author
        Nothing
        (case model.authorEvents of
            Success events ->
                Just events

            _ ->
                Nothing
        )


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
        [ button [ class "btn btn--danger btn--sm", id removeTriggerId, onClick OpenRemoveModal ]
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
            , id cardFocusId
            , attribute "role" "dialog"
            , attribute "aria-label" ariaLabel
            , attribute "aria-modal" "true"
            , tabindex -1
            , preventDefaultOn "keydown" trapKeydownDecoder
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
            , overlayFocusSentinel
            ]
        ]


{-| The trailing focus sentinel — the overlay's last tab stop. It is focusable
(`tabindex 0`) but visually collapsed. Forward Tab off it wraps to the close
button (via `trapKeydownDecoder`); Shift+Tab off the close button lands here.
-}
overlayFocusSentinel : Html Msg
overlayFocusSentinel =
    div
        [ id lastFocusableId
        , testId "book-overlay-focus-sentinel"
        , tabindex 0
        , attribute "aria-label" "End of book details — press Tab to return to the top"
        , class "book-overlay__focus-sentinel"
        , style "position" "absolute"
        , style "width" "1px"
        , style "height" "1px"
        , style "overflow" "hidden"
        , style "clip" "rect(0 0 0 0)"
        ]
        []


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
                            , onWrapToFirst = FocusOn RemoveBookModal.cancelButtonId
                            , onWrapToLast = FocusOn RemoveBookModal.confirmButtonId
                            }

                    _ ->
                        text ""

              else
                text ""
            ]
