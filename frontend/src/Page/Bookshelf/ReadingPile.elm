module Page.Bookshelf.ReadingPile exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api
import Browser.Dom
import Components.AgeGate exposing (ageGate)
import Components.PlacementCard as Card
import Components.Spine exposing (WearLevel(..))
import Html exposing (Html, button, div, p, text)
import Html.Attributes exposing (attribute, class, id, style)
import Html.Events exposing (onClick, onMouseEnter, stopPropagationOn)
import Http
import Json.Decode as Decode
import Navigation.Route exposing (Route(..))
import Page.Bookshelf.Helpers exposing (pickTexture)
import Task
import Types.Book exposing (Book, bookCoverImageUrl, bookPageCount)
import Types.Placement as Placement exposing (Placement, ReadingStatus(..), readingStatusToString)
import Types.RemoteData exposing (RemoteData(..))
import Types.Shelf exposing (Shelf)
import Util.TestId exposing (testId)


type alias Model =
    { books : RemoteData Http.Error (List Placement)
    , showAgeGate : Bool
    , selectedBookId : Maybe String
    , token : Maybe String
    , cards : List Card.Model
    , saveState : RemoteData Api.ProgressError ()
    , finishedPrompt : Maybe String
    }


type OutMsg
    = NoOut
    | NavigateTo Route
    | SessionExpired


type Msg
    = BooksLoaded (Result Http.Error (List Shelf))
    | DismissAgeGate
    | BookHovered String
    | BookClicked Book
    | Deselect
    | CardMsg String Card.Msg
    | ProgressSaved String (Result Api.ProgressError Api.Progress)
    | RecordReadRequested String
    | RecordReadDone String (Result Api.MoveError ())
    | FinishedPromptDismissed
    | FocusReturned


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    let
        cmd =
            case maybeToken of
                Just token ->
                    -- This page only needs the shelves; drop the response's
                    -- visibility (added for the RSS gate on Page.Bookshelf).
                    Api.getBookshelf "reading_pile" token (BooksLoaded << Result.map .shelves)

                Nothing ->
                    Cmd.none
    in
    ( { books = Loading
      , showAgeGate = False
      , selectedBookId = Nothing
      , token = maybeToken
      , cards = []
      , saveState = NotAsked
      , finishedPrompt = Nothing
      }
    , cmd
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        BooksLoaded result ->
            case result of
                Ok shelves ->
                    let
                        placements =
                            List.concatMap .placements shelves
                    in
                    ( { model | books = Success placements, cards = List.map Card.init placements }, Cmd.none, NoOut )

                Err (Http.BadStatus 403) ->
                    ( { model | books = Failure (Http.BadStatus 403), showAgeGate = True }, Cmd.none, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | books = Failure err }, Cmd.none, NoOut )

        DismissAgeGate ->
            ( { model | showAgeGate = False }, Cmd.none, NoOut )

        BookHovered bookId ->
            ( { model | selectedBookId = Just bookId }, Cmd.none, NoOut )

        BookClicked bk ->
            if model.selectedBookId == Just bk.id then
                ( model, Cmd.none, NavigateTo (BookDetail bk.id) )

            else
                ( { model | selectedBookId = Just bk.id }, Cmd.none, NoOut )

        Deselect ->
            ( { model | selectedBookId = Nothing }, Cmd.none, NoOut )

        CardMsg placementId cardMsg ->
            let
                ( updatedCards, outMsgs ) =
                    model.cards
                        |> List.map
                            (\c ->
                                if c.placement.id == placementId then
                                    Card.update cardMsg c

                                else
                                    ( c, Card.NoOut )
                            )
                        |> List.unzip

                requestedCard =
                    updatedCards
                        |> List.filter (\c -> c.placement.id == placementId)
                        |> List.head
            in
            if List.member Card.ProgressUpdateRequested outMsgs then
                case ( requestedCard, model.token ) of
                    ( Just c, Just token ) ->
                        ( { model | cards = updatedCards, saveState = Loading }
                        , Api.updateProgress c.placement.id
                            { readingStatus = readingStatusToString c.draftStatus
                            , currentPage = String.toInt c.draftPage
                            }
                            token
                            (ProgressSaved c.placement.id)
                        , NoOut
                        )

                    _ ->
                        ( { model | cards = updatedCards }, Cmd.none, NoOut )

            else if List.member Card.EditClosed outMsgs then
                -- Form closed by Cancel: return focus to the card's status badge.
                ( { model | cards = updatedCards }, focusBadge placementId, NoOut )

            else
                ( { model | cards = updatedCards }, Cmd.none, NoOut )

        ProgressSaved placementId result ->
            case result of
                Ok progress ->
                    let
                        newCards =
                            List.map
                                (\c ->
                                    if c.placement.id == placementId then
                                        Card.init (Api.foldProgress c.placement progress)

                                    else
                                        c
                                )
                                model.cards

                        prompt =
                            if progress.readingStatus == Just Completed then
                                Just placementId

                            else
                                model.finishedPrompt
                    in
                    -- Success closes the form (card re-init); return focus to the badge.
                    ( { model | cards = newCards, saveState = Success (), finishedPrompt = prompt }
                    , focusBadge placementId
                    , NoOut
                    )

                Err (Api.ProgressRequestFailed err) ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | cards = clearSaving placementId model.cards, saveState = Failure (Api.ProgressRequestFailed err) }, Cmd.none, NoOut )

                Err other ->
                    -- Keep the form open (draft preserved) so the reader can fix it.
                    ( { model | cards = clearSaving placementId model.cards, saveState = Failure other }, Cmd.none, NoOut )

        RecordReadRequested placementId ->
            case model.token of
                Just token ->
                    ( model, Api.moveBook placementId "library" token (RecordReadDone placementId), NoOut )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        RecordReadDone placementId result ->
            case result of
                Ok _ ->
                    ( { model
                        | cards = List.filter (\c -> c.placement.id /= placementId) model.cards
                        , books = removeFromBooks placementId model.books
                        , finishedPrompt = Nothing
                      }
                    , Cmd.none
                    , NoOut
                    )

                Err (Api.MoveHttpError err) ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | finishedPrompt = Nothing }, Cmd.none, NoOut )

                Err Api.ReadingPileFull ->
                    ( { model | finishedPrompt = Nothing }, Cmd.none, NoOut )

        FinishedPromptDismissed ->
            ( { model | finishedPrompt = Nothing }, Cmd.none, NoOut )

        FocusReturned ->
            ( model, Cmd.none, NoOut )


focusBadge : String -> Cmd Msg
focusBadge placementId =
    Browser.Dom.focus ("reading-status-badge-" ++ placementId)
        |> Task.attempt (\_ -> FocusReturned)


{-| Clear the in-flight save flag on the matching card, keeping its edit form
open and its draft intact so a failed save can be corrected and retried.
-}
clearSaving : String -> List Card.Model -> List Card.Model
clearSaving placementId cards =
    List.map
        (\c ->
            if c.placement.id == placementId then
                Card.stopSaving c

            else
                c
        )
        cards


removeFromBooks : String -> RemoteData Http.Error (List Placement) -> RemoteData Http.Error (List Placement)
removeFromBooks placementId books =
    case books of
        Success placements ->
            Success (List.filter (\p -> p.id /= placementId) placements)

        other ->
            other


view : Model -> Html Msg
view model =
    div
        [ class "page page--shelf shelf-reading-pile"
        , testId "reading-pile-page"
        , onClick Deselect
        ]
        [ div [ class "wallpaper wallpaper--dragons" ] []
        , div [ class "lighting" ] []
        , div [ class "reading-pile" ]
            [ div [ class "reading-pile__label" ] [ text "Reading Pile" ]
            , if model.showAgeGate then
                ageGate
                    { onDismiss = DismissAgeGate }

              else
                div [ class "reading-pile__scene" ]
                    [ div [ class "reading-pile__floor", attribute "aria-hidden" "true" ] []
                    , div [ class "reading-pile__chair-area" ]
                        [ case model.books of
                            NotAsked ->
                                text ""

                            Loading ->
                                div [ class "reading-pile__empty-msg" ]
                                    [ text "Loading your reading pile..." ]

                            Failure _ ->
                                p [ class "error" ]
                                    [ text "Could not load your reading pile. Please try again." ]

                            Success placements ->
                                if List.isEmpty placements then
                                    div [ class "reading-pile__empty-msg" ]
                                        [ text "Nothing on the pile right now. Move a book from your Antilibrary to start reading." ]

                                else
                                    viewBookPile model.selectedBookId placements
                        , div [ class "armchair", attribute "aria-hidden" "true" ]
                            [ div [ class "armchair__back" ] []
                            , div [ class "armchair__seat" ] []
                            , div [ class "armchair__arm armchair__arm--left" ] []
                            , div [ class "armchair__arm armchair__arm--right" ] []
                            , div [ class "armchair__leg armchair__leg--fl" ] []
                            , div [ class "armchair__leg armchair__leg--fr" ] []
                            , div [ class "armchair__leg armchair__leg--bl" ] []
                            , div [ class "armchair__leg armchair__leg--br" ] []
                            ]
                        ]
                    ]

            -- Sibling of the scene, not a child: inside the scene's
            -- bottom-aligned flex row the panel floated mid-wall beside the
            -- armchair (#324 0g). Its CSS (margin: 1.5rem auto 0) expects
            -- below-scene flow.
            , if model.showAgeGate then
                text ""

              else
                viewProgressPanel model
            ]
        ]


{-| The reading-progress panel: one PlacementCard per book on the pile (status
badge + inline edit), plus any save error and the "record this read?" bridge
prompt raised when a book is marked Finished.
-}
viewProgressPanel : Model -> Html Msg
viewProgressPanel model =
    if List.isEmpty model.cards then
        text ""

    else
        div [ class "reading-pile__progress", testId "reading-progress-panel" ]
            (List.map viewCard model.cards
                ++ [ viewSaveState model.saveState
                   , viewFinishedPrompt model.finishedPrompt
                   ]
            )


viewCard : Card.Model -> Html Msg
viewCard card =
    Html.map (CardMsg card.placement.id) (Card.view card)


viewSaveState : RemoteData Api.ProgressError () -> Html Msg
viewSaveState state =
    case state of
        Failure err ->
            p
                [ class "error"
                , attribute "role" "alert"
                , id "progress-error"
                , testId "progress-error"
                ]
                [ text (Api.progressErrorMessage err) ]

        _ ->
            text ""


viewFinishedPrompt : Maybe String -> Html Msg
viewFinishedPrompt maybeId =
    case maybeId of
        Just placementId ->
            div [ class "reading-pile__finished-prompt", testId "finished-read-prompt" ]
                [ p [] [ text "Move to your Library and record this read?" ]
                , button
                    [ class "btn btn--primary"
                    , onClick (RecordReadRequested placementId)
                    , testId "record-read-btn"
                    ]
                    [ text "Move to Library" ]
                , button
                    [ class "btn btn--ghost"
                    , onClick FinishedPromptDismissed
                    ]
                    [ text "Not now" ]
                ]

        Nothing ->
            text ""


viewBookPile : Maybe String -> List Placement -> Html Msg
viewBookPile selectedBookId placements =
    -- #276: no `List.take 50` here — deliberately removed. The 50-book cap is
    -- enforced at the write path (Stacks.Shelving.reading_pile_limit/0), and
    -- piles that already exceeded it are grandfathered: every book they hold
    -- must render. A view-layer truncation would silently hide those books,
    -- which was the original defect.
    div [ class "book-pile", attribute "role" "list" ]
        (List.indexedMap (viewPiledBook selectedBookId) placements)


viewPiledBook : Maybe String -> Int -> Placement -> Html Msg
viewPiledBook selectedBookId index placement =
    let
        bookData =
            case placement.book of
                Just bk ->
                    bk

                Nothing ->
                    { id = ""
                    , title = "Unknown Title"
                    , author = Nothing
                    , description = Nothing
                    , editions = []
                    , primaryEdition = Nothing
                    , editionCount = 0
                    , subjects = []
                    , visibilityTier = Types.Book.Public
                    }

        pageCount =
            Maybe.withDefault 200 (bookPageCount bookData)

        texture =
            pickTexture bookData.title

        spineW =
            Components.Spine.spineWidth pageCount

        spineH =
            Components.Spine.spineHeight pageCount

        offset =
            (modBy 5 (index * 3 + 2) - 2) * 3

        isSelected =
            selectedBookId == Just bookData.id

        bookClass =
            if isSelected then
                "book-pile__book book-pile__book--selected"

            else
                "book-pile__book"
    in
    button
        [ class bookClass
        , attribute "role" "listitem"
        , onMouseEnter (BookHovered bookData.id)
        , stopPropagationOn "click"
            (Decode.succeed ( BookClicked bookData, True ))
        , style "width" (String.fromInt spineH ++ "px")
        , style "height" (String.fromInt spineW ++ "px")
        , style "margin-left" (String.fromInt offset ++ "px")
        ]
        [ div [ class "book-pile__rotated-book" ]
            [ Components.Spine.book
                { pageCount = pageCount
                , wearLevel = Softened
                , texture = texture
                , title = bookData.title
                , author = Types.Book.authorName bookData
                , coverImageUrl = bookCoverImageUrl bookData
                , hidden = Placement.isHidden placement
                , hasWriting = placement.hasUserWriting
                }
            ]
        ]
