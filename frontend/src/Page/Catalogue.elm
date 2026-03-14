module Page.Catalogue exposing
    ( Model
    , Msg(..)
    , init
    , update
    , view
    )

{-| Global Book Catalogue page.

Displays all books in the system as a browsable, searchable catalogue.
No ownership data is shown — this is a pure discovery and exploration view.

Users can search by title/author, filter by subject, sort results,
and click through to the book detail page.

-}

import Api exposing (CatalogueResponse)
import Html exposing (Html, a, button, div, h1, h3, img, input, option, p, select, span, text)
import Html.Attributes exposing (class, href, placeholder, selected, src, type_, value)
import Html.Events exposing (onClick, onInput)
import Http
import Navigation.Route as Route
import Process
import Task
import Types.Book exposing (Book, authorName)
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { books : RemoteData Http.Error CatalogueResponse
    , search : String
    , activeSubject : Maybe String
    , sort : String
    , page : Int
    , availableSubjects : List String
    , debounceCount : Int
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
            }
    in
    ( model
    , fetchCatalogue model maybeToken
    )


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg )
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
                    )

                Err err ->
                    ( { model | books = Failure err }, Cmd.none )

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
            )

        ClearSearch ->
            let
                newModel =
                    { model | search = "", page = 1, books = Loading }
            in
            ( newModel, fetchCatalogue newModel maybeToken )

        DebounceExpired count ->
            if count == model.debounceCount then
                let
                    newModel =
                        { model | page = 1 }
                in
                ( newModel, fetchCatalogue newModel maybeToken )

            else
                ( model, Cmd.none )

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
            ( newModel, fetchCatalogue newModel maybeToken )

        ClearSubject ->
            let
                newModel =
                    { model | activeSubject = Nothing, page = 1, books = Loading }
            in
            ( newModel, fetchCatalogue newModel maybeToken )

        SortChanged newSort ->
            let
                newModel =
                    { model | sort = newSort, page = 1, books = Loading }
            in
            ( newModel, fetchCatalogue newModel maybeToken )

        PageChanged newPage ->
            let
                newModel =
                    { model | page = newPage, books = Loading }
            in
            ( newModel, fetchCatalogue newModel maybeToken )


fetchCatalogue : Model -> Maybe String -> Cmd Msg
fetchCatalogue model maybeToken =
    case maybeToken of
        Just token ->
            Api.getCatalogue
                { search =
                    if String.isEmpty model.search then
                        Nothing

                    else
                        Just model.search
                , subject = model.activeSubject
                , sort = model.sort
                , page = model.page
                }
                token
                CatalogueReceived

        Nothing ->
            Cmd.none



-- VIEW


view : Model -> Html Msg
view model =
    div [ class "page page--catalogue" ]
        [ h1 [ class "page__title catalogue__title" ] [ text "Book Catalogue" ]
        , p [ class "catalogue__subtitle" ]
            [ text "Browse and discover books in the collection." ]
        , viewControls model
        , viewContent model
        ]


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
            [ viewSubjectFilter model
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
            if List.isEmpty response.books then
                p [ class "catalogue__empty" ]
                    [ text "No books found matching your criteria." ]

            else
                div []
                    [ div [ class "catalogue__grid" ]
                        (List.map viewBookCard response.books)
                    , viewPagination response
                    ]


viewBookCard : Book -> Html Msg
viewBookCard book =
    a
        [ class "catalogue__card"
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


viewBookCover : Book -> Html Msg
viewBookCover book =
    case book.coverImageUrl of
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



-- HELPERS


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
