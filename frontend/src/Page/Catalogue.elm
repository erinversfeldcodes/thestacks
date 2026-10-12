module Page.Catalogue exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , catalogueRequest
    , init
    , update
    , view
    )

{-| Global Book Catalogue page.

Displays all books in the system as a browsable, searchable catalogue.
Users can search by title/author, filter by subject, sort results,
and click through to the book detail page.

Books already on a user's shelf show a badge. Books not yet placed
can be added via an inline shelf picker.

-}

import Api exposing (CatalogueResponse, PlacementSummary)
import Html exposing (Html, a, button, div, h1, h3, img, input, option, p, select, span, text)
import Html.Attributes exposing (attribute, class, href, placeholder, selected, src, type_, value)
import Html.Events exposing (onClick, onInput)
import Http
import Navigation.Route as Route
import Process
import Task
import Types.Book exposing (Book, authorName, bookCoverImageUrl)
import Types.Placement exposing (Placement)
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


type CollectionFilter
    = AllBooks
    | InMyCollection
    | NotInMyCollection


type alias Model =
    { books : RemoteData Http.Error CatalogueResponse
    , search : String
    , activeSubject : Maybe String
    , sort : String
    , page : Int
    , availableSubjects : List String
    , debounceCount : Int
    , userPlacements : RemoteData Http.Error (List PlacementSummary)
    , shelfPickerBookId : Maybe String
    , placeBookState : RemoteData Api.PlaceError ()
    , collectionFilter : CollectionFilter
    , isAuthenticated : Bool
    }


type Msg
    = CatalogueReceived (Result Http.Error CatalogueResponse)
    | SearchChanged String
    | ClearSearch
    | SubjectSelected String
    | ClearSubject
    | SortChanged String
    | PageChanged Int
    | DebounceExpired Int
    | UserPlacementsLoaded (Result Http.Error (List PlacementSummary))
    | OpenShelfPicker String
    | CloseShelfPicker
    | PlaceOnShelf String String
    | CollectionFilterChanged CollectionFilter
    | PlaceBookCompleted String String (Result Api.PlaceError Placement)


type OutMsg
    = NoOut
    | SessionExpired


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    let
        model =
            { books = Loading
            , search = ""
            , activeSubject = Nothing
            , sort = "title"
            , page = 1
            , availableSubjects = []
            , debounceCount = 0
            , userPlacements = initialPlacements
            , shelfPickerBookId = Nothing
            , placeBookState = NotAsked
            , collectionFilter = AllBooks
            , isAuthenticated = maybeToken /= Nothing
            }

        ( initialPlacements, placementsCmd ) =
            case maybeToken of
                Just token ->
                    ( Loading, Api.getUserPlacements token UserPlacementsLoaded )

                Nothing ->
                    ( Success [], Cmd.none )
    in
    ( model
    , Cmd.batch [ fetchCatalogue model, placementsCmd ]
    )


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        CatalogueReceived result ->
            case result of
                Ok response ->
                    let
                        newSubjects =
                            response.books
                                |> List.concatMap .subjects
                                |> uniqueStrings
                                |> List.sort

                        merged =
                            mergeSubjects model.availableSubjects newSubjects
                    in
                    ( { model
                        | books = Success response
                        , availableSubjects = merged
                      }
                    , Cmd.none
                    , NoOut
                    )

                Err err ->
                    ( { model | books = Failure err }, Cmd.none, NoOut )

        UserPlacementsLoaded result ->
            case result of
                Ok placements ->
                    ( { model | userPlacements = Success placements }, Cmd.none, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | userPlacements = Success [] }, Cmd.none, NoOut )

        SearchChanged query ->
            let
                newCount =
                    model.debounceCount + 1

                debounceCmd =
                    Task.perform (\_ -> DebounceExpired newCount)
                        (Process.sleep 300)
            in
            ( { model
                | search = query
                , debounceCount = newCount
                , books = Loading
              }
            , debounceCmd
            , NoOut
            )

        ClearSearch ->
            let
                newModel =
                    { model | search = "", page = 1, books = Loading }
            in
            ( newModel, fetchCatalogue newModel, NoOut )

        DebounceExpired count ->
            if count == model.debounceCount then
                let
                    newModel =
                        { model | page = 1 }
                in
                ( newModel, fetchCatalogue newModel, NoOut )

            else
                ( model, Cmd.none, NoOut )

        SubjectSelected subject ->
            let
                newModel =
                    { model
                        | activeSubject =
                            if String.isEmpty subject then
                                Nothing

                            else
                                Just subject
                        , page = 1
                        , books = Loading
                    }
            in
            ( newModel, fetchCatalogue newModel, NoOut )

        ClearSubject ->
            let
                newModel =
                    { model | activeSubject = Nothing, page = 1, books = Loading }
            in
            ( newModel, fetchCatalogue newModel, NoOut )

        SortChanged newSort ->
            let
                newModel =
                    { model | sort = newSort, page = 1, books = Loading }
            in
            ( newModel, fetchCatalogue newModel, NoOut )

        PageChanged newPage ->
            let
                newModel =
                    { model | page = newPage, books = Loading }
            in
            ( newModel, fetchCatalogue newModel, NoOut )

        CollectionFilterChanged filter ->
            ( { model | collectionFilter = filter }, Cmd.none, NoOut )

        OpenShelfPicker bookId ->
            ( { model | shelfPickerBookId = Just bookId }, Cmd.none, NoOut )

        CloseShelfPicker ->
            ( { model | shelfPickerBookId = Nothing }, Cmd.none, NoOut )

        PlaceOnShelf shelfName bookId ->
            case maybeToken of
                Just token ->
                    ( { model | shelfPickerBookId = Nothing, placeBookState = Loading }
                    , Api.placeBook shelfName bookId token (PlaceBookCompleted shelfName bookId)
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        PlaceBookCompleted shelfName bookId result ->
            case result of
                Ok _ ->
                    let
                        newSummary =
                            { bookId = bookId, bookshelfName = shelfName }

                        updatedPlacements =
                            case model.userPlacements of
                                Success existing ->
                                    Success (newSummary :: existing)

                                _ ->
                                    Success [ newSummary ]
                    in
                    ( { model | placeBookState = NotAsked, userPlacements = updatedPlacements }, Cmd.none, NoOut )

                Err Api.PlaceReadingPileFull ->
                    ( { model | placeBookState = Failure Api.PlaceReadingPileFull }, Cmd.none, NoOut )

                Err (Api.PlaceHttpError err) ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | placeBookState = Failure (Api.PlaceHttpError err) }, Cmd.none, NoOut )


fetchCatalogue : Model -> Cmd Msg
fetchCatalogue model =
    Api.getCatalogue (catalogueParams model) CatalogueReceived


{-| The catalogue page this model asks for, as request data — search, subject,
sort and page are all in the URL, so this is where they are decided.
-}
catalogueRequest : Model -> Api.RequestSpec
catalogueRequest model =
    Api.getCatalogueRequest (catalogueParams model)


catalogueParams :
    Model
    -> { search : Maybe String, subject : Maybe String, sort : String, page : Int }
catalogueParams model =
    { search =
        if String.isEmpty model.search then
            Nothing

        else
            Just model.search
    , subject = model.activeSubject
    , sort = model.sort
    , page = model.page
    }


view : Model -> Html Msg
view model =
    div [ class "page page--catalogue", testId "catalogue-page" ]
        [ h1 [ class "page__title catalogue__title" ] [ text "Book Catalogue" ]
        , p [ class "catalogue__subtitle" ]
            [ text "Browse and discover books in the collection." ]
        , viewControls model
        , viewPlaceError model.placeBookState
        , viewContent model
        ]


{-| : the direct-place path can hit the reading-pile cap. Surface the
specific full-pile copy (shared with the move/upload paths) as a page-level
notice; transport failures stay silent here, as before.
-}
viewPlaceError : RemoteData Api.PlaceError () -> Html Msg
viewPlaceError state =
    case state of
        Failure Api.PlaceReadingPileFull ->
            p
                [ class "catalogue__error error"
                , attribute "role" "alert"
                , testId "reading-pile-full-msg"
                ]
                [ text "Your reading pile is full — finish or remove a book before adding another." ]

        _ ->
            text ""


viewControls : Model -> Html Msg
viewControls model =
    div [ class "catalogue__controls" ]
        [ div [ class "search-bar" ]
            [ input
                [ type_ "text"
                , class "search-bar__input"
                , placeholder "Search by title or author..."
                , value model.search
                , onInput SearchChanged
                ]
                []
            , if String.isEmpty model.search then
                text ""

              else
                button [ class "search-bar__clear", onClick ClearSearch ] [ text "Clear" ]
            ]
        , div [ class "catalogue__filters" ]
            [ viewCollectionFilter model
            , viewSubjectFilter model
            , viewSortSelector model
            ]
        ]


viewSubjectFilter : Model -> Html Msg
viewSubjectFilter model =
    if List.isEmpty model.availableSubjects then
        text ""

    else
        div [ class "catalogue__subject-filter" ]
            [ select
                [ class "catalogue__subject-select"
                , onInput SubjectSelected
                ]
                (option [ value "", selected (model.activeSubject == Nothing) ] [ text "All Subjects" ]
                    :: List.map
                        (\subject ->
                            option
                                [ value subject
                                , selected (model.activeSubject == Just subject)
                                ]
                                [ text subject ]
                        )
                        model.availableSubjects
                )
            , case model.activeSubject of
                Just _ ->
                    button [ class "btn btn--ghost btn--sm", onClick ClearSubject ] [ text "Clear filter" ]

                Nothing ->
                    text ""
            ]


viewCollectionFilter : Model -> Html Msg
viewCollectionFilter model =
    if not model.isAuthenticated then
        text ""

    else
        div [ class "catalogue__collection-filter" ]
            [ button
                [ class
                    (if model.collectionFilter == AllBooks then
                        "catalogue__filter-btn catalogue__filter-btn--active"

                     else
                        "catalogue__filter-btn"
                    )
                , onClick (CollectionFilterChanged AllBooks)
                ]
                [ text "All" ]
            , button
                [ class
                    (if model.collectionFilter == InMyCollection then
                        "catalogue__filter-btn catalogue__filter-btn--active"

                     else
                        "catalogue__filter-btn"
                    )
                , onClick (CollectionFilterChanged InMyCollection)
                ]
                [ text "In my collection" ]
            , button
                [ class
                    (if model.collectionFilter == NotInMyCollection then
                        "catalogue__filter-btn catalogue__filter-btn--active"

                     else
                        "catalogue__filter-btn"
                    )
                , onClick (CollectionFilterChanged NotInMyCollection)
                ]
                [ text "Not in my collection" ]
            ]


viewSortSelector : Model -> Html Msg
viewSortSelector model =
    div [ class "sort-selector" ]
        [ span [ class "sort-selector__label" ] [ text "Sort:" ]
        , select [ class "sort-selector__select", onInput SortChanged ]
            [ option [ value "title", selected (model.sort == "title") ] [ text "Title A–Z" ]
            , option [ value "author", selected (model.sort == "author") ] [ text "Author A–Z" ]
            , option [ value "recent", selected (model.sort == "recent") ] [ text "Recently Added" ]
            ]
        ]


viewContent : Model -> Html Msg
viewContent model =
    case model.books of
        NotAsked ->
            text ""

        Loading ->
            div [ class "loading" ] [ text "Loading catalogue..." ]

        Failure _ ->
            p [ class "error" ] [ text "Failed to load the catalogue. Please try again." ]

        Success response ->
            let
                filteredBooks =
                    applyCollectionFilter model.collectionFilter model.userPlacements response.books
            in
            if List.isEmpty filteredBooks then
                p [ class "catalogue__empty" ]
                    [ text "No books found matching your criteria." ]

            else
                div []
                    [ div [ class "catalogue__grid", testId "catalogue-grid" ]
                        (List.map (viewBookCard model) filteredBooks)
                    , viewPagination response
                    ]


viewBookCard : Model -> Book -> Html Msg
viewBookCard model book =
    let
        maybePlacement =
            findPlacement model.userPlacements book.id

        shelfPickerOpen =
            model.shelfPickerBookId == Just book.id
    in
    div [ class "catalogue__card" ]
        [ a
            [ class "catalogue__card-link"
            , href (Route.toPath (Route.BookDetail book.id))
            ]
            [ viewBookCover book
            , div [ class "catalogue__card-info" ]
                [ h3 [ class "catalogue__card-title" ] [ text book.title ]
                , p [ class "catalogue__card-author" ] [ text (authorName book) ]
                , if List.isEmpty book.subjects then
                    text ""

                  else
                    div [ class "catalogue__card-subjects" ]
                        (List.map
                            (\subject ->
                                span [ class "catalogue__subject-chip" ] [ text subject ]
                            )
                            (List.take 3 book.subjects)
                        )
                ]
            ]
        , viewShelfAction book maybePlacement shelfPickerOpen
        ]


viewShelfAction : Book -> Maybe PlacementSummary -> Bool -> Html Msg
viewShelfAction book maybePlacement shelfPickerOpen =
    case maybePlacement of
        Just placement ->
            span [ class "catalogue__card-badge", attribute "role" "status" ]
                [ text (placementBadgeText placement.bookshelfName) ]

        Nothing ->
            if shelfPickerOpen then
                viewShelfPicker book.id

            else
                button
                    [ class "catalogue__card-add"
                    , attribute "aria-label" ("Add " ++ book.title ++ " to a bookshelf")
                    , onClick (OpenShelfPicker book.id)
                    ]
                    [ text "Add to Shelf" ]


viewShelfPicker : String -> Html Msg
viewShelfPicker bookId =
    div [ class "catalogue__card-picker" ]
        [ div [ attribute "role" "listbox", attribute "aria-label" "Choose a bookshelf" ]
            (List.map
                (\shelf ->
                    button
                        [ class "catalogue__card-picker-option"
                        , onClick (PlaceOnShelf shelf.value bookId)
                        ]
                        [ text shelf.label ]
                )
                allBookshelves
            )
        , button
            [ class "btn btn--ghost btn--sm"
            , onClick CloseShelfPicker
            ]
            [ text "Cancel" ]
        ]


allBookshelves : List { value : String, label : String }
allBookshelves =
    [ { value = "library", label = "Library" }
    , { value = "antilibrary", label = "Antilibrary" }
    , { value = "wishlist", label = "Wish List" }
    , { value = "reading_pile", label = "Reading Pile" }
    , { value = "looking_for_home", label = "Looking for a Home" }
    ]


placementBadgeText : String -> String
placementBadgeText name =
    case name of
        "library" ->
            "In your Library"

        "antilibrary" ->
            "In your Antilibrary"

        "wishlist" ->
            "On your Wish List"

        "reading_pile" ->
            "In your Reading Pile"

        "looking_for_home" ->
            "You're rehoming"

        other ->
            "On your " ++ other


viewBookCover : Book -> Html Msg
viewBookCover book =
    case bookCoverImageUrl book of
        Just url ->
            img
                [ src url
                , class "catalogue__card-cover"
                , Html.Attributes.alt (book.title ++ " cover")
                ]
                []

        Nothing ->
            div [ class "catalogue__card-cover-placeholder" ]
                [ span [] [ text (String.left 1 book.title) ] ]


viewPagination : CatalogueResponse -> Html Msg
viewPagination response =
    let
        totalPages =
            ceiling (toFloat response.total / toFloat response.perPage)

        hasPrev =
            response.page > 1

        hasNext =
            response.page < totalPages
    in
    if totalPages <= 1 then
        text ""

    else
        div [ class "catalogue__pagination" ]
            [ if hasPrev then
                button
                    [ class "btn btn--secondary btn--sm"
                    , onClick (PageChanged (response.page - 1))
                    ]
                    [ text "Previous" ]

              else
                text ""
            , span [ class "catalogue__page-info" ]
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


applyCollectionFilter : CollectionFilter -> RemoteData Http.Error (List PlacementSummary) -> List Book -> List Book
applyCollectionFilter filter remotePlacements books =
    case filter of
        AllBooks ->
            books

        InMyCollection ->
            List.filter (\book -> findPlacement remotePlacements book.id /= Nothing) books

        NotInMyCollection ->
            List.filter (\book -> findPlacement remotePlacements book.id == Nothing) books


findPlacement : RemoteData Http.Error (List PlacementSummary) -> String -> Maybe PlacementSummary
findPlacement remotePlacements bookId =
    case remotePlacements of
        Success placements ->
            List.filter (\p -> p.bookId == bookId) placements
                |> List.head

        _ ->
            Nothing


uniqueStrings : List String -> List String
uniqueStrings list =
    List.foldl
        (\item acc ->
            if List.member item acc then
                acc

            else
                acc ++ [ item ]
        )
        []
        list


mergeSubjects : List String -> List String -> List String
mergeSubjects existing new =
    (existing ++ new)
        |> uniqueStrings
        |> List.sort
