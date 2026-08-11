module Page.Admin.BookModeration exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

{-| Admin Book Moderation page (#118).

Displays books in a filterable, paginated list. The platform owner can
raise or lower a book's age gate in EITHER direction — the human-set
replacement for the removed automatic classifier.

-}

import Api exposing (AdminBook, AdminBooksResponse)
import Html exposing (Html, button, div, form, h1, input, p, span, table, tbody, td, text, th, thead, tr)
import Html.Attributes exposing (class, disabled, placeholder, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Http
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


type TierFilter
    = AllTiers
    | PublicOnly
    | AgeGatedOnly


type alias Model =
    { books : RemoteData Http.Error AdminBooksResponse
    , tierFilter : TierFilter
    , search : String
    , page : Int
    , actionInProgress : Maybe String
    , actionError : Maybe String
    }


type Msg
    = BooksReceived (Result Http.Error AdminBooksResponse)
    | SetTierFilter TierFilter
    | SearchChanged String
    | SearchSubmitted
    | PageChanged Int
    | ToggleAgeGate String Bool
    | AgeGateCompleted String (Result Http.Error AdminBook)


type OutMsg
    = NoOut
    | SessionExpired


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    let
        model =
            { books = Loading
            , tierFilter = AllTiers
            , search = ""
            , page = 1
            , actionInProgress = Nothing
            , actionError = Nothing
            }
    in
    ( model, fetchBooks model maybeToken )


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        BooksReceived result ->
            case result of
                Ok response ->
                    ( { model | books = Success response }, Cmd.none, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | books = Failure err }, Cmd.none, NoOut )

        SetTierFilter filter ->
            let
                newModel =
                    { model | tierFilter = filter, page = 1, books = Loading }
            in
            ( newModel, fetchBooks newModel maybeToken, NoOut )

        SearchChanged value ->
            ( { model | search = value }, Cmd.none, NoOut )

        SearchSubmitted ->
            let
                newModel =
                    { model | page = 1, books = Loading }
            in
            ( newModel, fetchBooks newModel maybeToken, NoOut )

        PageChanged newPage ->
            let
                newModel =
                    { model | page = newPage, books = Loading }
            in
            ( newModel, fetchBooks newModel maybeToken, NoOut )

        ToggleAgeGate bookId newAgeGated ->
            case maybeToken of
                Just token ->
                    ( { model | actionInProgress = Just bookId }
                    , Api.adminSetBookAgeGate bookId newAgeGated token (AgeGateCompleted bookId)
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        AgeGateCompleted bookId result ->
            case result of
                Ok updatedBook ->
                    let
                        updatedBooks =
                            case model.books of
                                Success response ->
                                    Success
                                        { response
                                            | books =
                                                List.map
                                                    (\b ->
                                                        if b.id == bookId then
                                                            updatedBook

                                                        else
                                                            b
                                                    )
                                                    response.books
                                        }

                                other ->
                                    other
                    in
                    ( { model | books = updatedBooks, actionInProgress = Nothing, actionError = Nothing }
                    , Cmd.none
                    , NoOut
                    )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | actionInProgress = Nothing, actionError = Just "Action failed. Please try again." }
                        , Cmd.none
                        , NoOut
                        )


fetchBooks : Model -> Maybe String -> Cmd Msg
fetchBooks model maybeToken =
    case maybeToken of
        Just token ->
            Api.adminListBooks
                { tier = tierFilterToString model.tierFilter
                , search = searchToMaybe model.search
                , page = model.page
                }
                token
                BooksReceived

        Nothing ->
            Cmd.none


tierFilterToString : TierFilter -> Maybe String
tierFilterToString filter =
    case filter of
        AllTiers ->
            Nothing

        PublicOnly ->
            Just "public"

        AgeGatedOnly ->
            Just "age_gated"


searchToMaybe : String -> Maybe String
searchToMaybe s =
    if String.trim s == "" then
        Nothing

    else
        Just (String.trim s)


view : Model -> Html Msg
view model =
    div [ class "page page--admin", testId "admin-book-moderation" ]
        [ h1 [ class "page__title admin__title" ] [ text "Book Moderation" ]
        , p [ class "admin__subtitle" ]
            [ text "Review books and set the age gate in either direction." ]
        , case model.actionError of
            Just err ->
                p [ class "admin__error" ] [ text err ]

            Nothing ->
                text ""
        , viewFilterTabs model.tierFilter
        , viewSearch model.search
        , viewContent model
        ]


viewFilterTabs : TierFilter -> Html Msg
viewFilterTabs active =
    div [ class "admin__tabs" ]
        [ filterTab AllTiers "All" active
        , filterTab PublicOnly "Public" active
        , filterTab AgeGatedOnly "Age-gated" active
        ]


filterTab : TierFilter -> String -> TierFilter -> Html Msg
filterTab filter label active =
    button
        [ class
            (if filter == active then
                "admin__tab admin__tab--active"

             else
                "admin__tab"
            )
        , onClick (SetTierFilter filter)
        ]
        [ text label ]


viewSearch : String -> Html Msg
viewSearch current =
    form [ class "admin__search", onSubmit SearchSubmitted ]
        [ input
            [ class "admin__search-input"
            , placeholder "Search by title…"
            , value current
            , onInput SearchChanged
            , testId "book-mod-search"
            ]
            []
        , button [ class "btn btn--secondary btn--sm" ] [ text "Search" ]
        ]


viewContent : Model -> Html Msg
viewContent model =
    case model.books of
        NotAsked ->
            text ""

        Loading ->
            div [ class "loading" ] [ text "Loading books..." ]

        Failure _ ->
            p [ class "error" ] [ text "Failed to load books. Please try again." ]

        Success response ->
            if List.isEmpty response.books then
                p [ class "admin__empty" ] [ text "No books found." ]

            else
                div []
                    [ viewBooksTable model.actionInProgress response.books
                    , viewPagination response
                    ]


viewBooksTable : Maybe String -> List AdminBook -> Html Msg
viewBooksTable actionInProgress books =
    table [ class "metrics-table" ]
        [ thead []
            [ tr []
                [ th [] [ text "Title" ]
                , th [] [ text "Author" ]
                , th [] [ text "Tier" ]
                , th [] [ text "Actions" ]
                ]
            ]
        , tbody []
            (List.map (viewBookRow actionInProgress) books)
        ]


viewBookRow : Maybe String -> AdminBook -> Html Msg
viewBookRow actionInProgress book =
    let
        isProcessing =
            actionInProgress == Just book.id

        isAgeGated =
            book.visibilityTier == "age_gated"

        ( toggleLabel, newAgeGated ) =
            if isAgeGated then
                ( "Un-gate", False )

            else
                ( "Mark age-gated", True )
    in
    tr [ testId "book-mod-row" ]
        [ td [] [ text book.title ]
        , td [] [ text book.author ]
        , td [] [ viewTierBadge book.visibilityTier ]
        , td []
            [ button
                [ class
                    (if isAgeGated then
                        "btn btn--secondary btn--sm"

                     else
                        "btn btn--danger btn--sm"
                    )
                , onClick (ToggleAgeGate book.id newAgeGated)
                , disabled isProcessing
                , testId "book-mod-toggle"
                ]
                [ text toggleLabel ]
            ]
        ]


viewTierBadge : String -> Html Msg
viewTierBadge tier =
    let
        badgeClass =
            case tier of
                "age_gated" ->
                    "status-badge--degraded"

                _ ->
                    "status-badge--healthy"
    in
    span [ class ("status-badge " ++ badgeClass) ] [ text tier ]


viewPagination : AdminBooksResponse -> Html Msg
viewPagination response =
    let
        totalPages =
            ceiling (toFloat response.total / toFloat (max response.perPage 1))

        hasPrev =
            response.page > 1

        hasNext =
            response.page < totalPages
    in
    if totalPages <= 1 then
        text ""

    else
        div [ class "admin__pagination" ]
            [ if hasPrev then
                button
                    [ class "btn btn--secondary btn--sm"
                    , onClick (PageChanged (response.page - 1))
                    ]
                    [ text "Previous" ]

              else
                text ""
            , span [ class "admin__page-info" ]
                [ text ("Page " ++ String.fromInt response.page ++ " of " ++ String.fromInt totalPages) ]
            , if hasNext then
                button
                    [ class "btn btn--secondary btn--sm"
                    , onClick (PageChanged (response.page + 1))
                    ]
                    [ text "Next" ]

              else
                text ""
            ]
