module Page.CatalogueProgramTest exposing (suite)

{-| Program tests for Page.Catalogue using elm-program-test.

These tests exercise the Catalogue page lifecycle through
simulated user interactions and HTTP responses.

-}

import Api exposing (CatalogueResponse)
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Page.Catalogue as Catalogue exposing (Msg(..))
import ProgramTest exposing (ProgramDefinition, SimulatedEffect)
import SimulatedEffect.Cmd
import SimulatedEffect.Http
import SimulatedEffect.Process
import SimulatedEffect.Task
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import Types.Book exposing (bookDecoder)


suite : Test
suite =
    describe "Page.Catalogue (ProgramTest)"
        [ loadAndDisplayBooks
        , showsLoadingState
        , showsErrorState
        , showsEmptyState
        , searchTriggersDebounce
        , sortChangeFetchesNewData
        , rendersAgeGatedBooksWithNullAuthor
        ]


startCatalogue : ProgramTest.ProgramTest Catalogue.Model Catalogue.Msg (SimulatedEffect Catalogue.Msg)
startCatalogue =
    ProgramTest.start () (catalogueProgram (Just "test-token"))


catalogueProgram : Maybe String -> ProgramDefinition () Catalogue.Model Catalogue.Msg (SimulatedEffect Catalogue.Msg)
catalogueProgram maybeToken =
    ProgramTest.createElement
        { init =
            \() ->
                let
                    ( model, _ ) =
                        Catalogue.init maybeToken
                in
                ( model, catalogueInitEffects maybeToken )
        , update =
            \msg model ->
                let
                    ( newModel, _ ) =
                        Catalogue.update msg model maybeToken
                in
                ( newModel, catalogueEffects msg model maybeToken )
        , view = Catalogue.view
        }
        |> ProgramTest.withSimulatedEffects identity


catalogueInitEffects : Maybe String -> SimulatedEffect Catalogue.Msg
catalogueInitEffects maybeToken =
    case maybeToken of
        Just token ->
            SimulatedEffect.Http.request
                { method = "GET"
                , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                , url = "/api/catalogue?sort=title&page=1"
                , body = SimulatedEffect.Http.emptyBody
                , expect = SimulatedEffect.Http.expectJson Catalogue.CatalogueReceived catalogueResponseDecoder
                , timeout = Nothing
                , tracker = Nothing
                }

        Nothing ->
            SimulatedEffect.Cmd.none


catalogueEffects : Catalogue.Msg -> Catalogue.Model -> Maybe String -> SimulatedEffect Catalogue.Msg
catalogueEffects msg model maybeToken =
    case msg of
        Catalogue.SearchChanged _ ->
            let
                newCount =
                    model.debounceCount + 1
            in
            SimulatedEffect.Task.perform (\_ -> Catalogue.DebounceExpired newCount) (SimulatedEffect.Process.sleep 300)

        Catalogue.DebounceExpired count ->
            if count == model.debounceCount then
                fetchSimulated model maybeToken

            else
                SimulatedEffect.Cmd.none

        Catalogue.ClearSearch ->
            fetchSimulated { model | search = "", page = 1 } maybeToken

        Catalogue.SubjectSelected _ ->
            fetchSimulated model maybeToken

        Catalogue.ClearSubject ->
            fetchSimulated { model | activeSubject = Nothing, page = 1 } maybeToken

        Catalogue.SortChanged newSort ->
            fetchSimulated { model | sort = newSort, page = 1 } maybeToken

        Catalogue.PageChanged newPage ->
            fetchSimulated { model | page = newPage } maybeToken

        _ ->
            SimulatedEffect.Cmd.none


fetchSimulated : Catalogue.Model -> Maybe String -> SimulatedEffect Catalogue.Msg
fetchSimulated model maybeToken =
    case maybeToken of
        Just token ->
            let
                searchParam =
                    if String.isEmpty model.search then
                        ""

                    else
                        "&search=" ++ model.search

                subjectParam =
                    case model.activeSubject of
                        Just subject ->
                            "&subject=" ++ subject

                        Nothing ->
                            ""
            in
            SimulatedEffect.Http.request
                { method = "GET"
                , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                , url = "/api/catalogue?sort=" ++ model.sort ++ "&page=" ++ String.fromInt model.page ++ searchParam ++ subjectParam
                , body = SimulatedEffect.Http.emptyBody
                , expect = SimulatedEffect.Http.expectJson Catalogue.CatalogueReceived catalogueResponseDecoder
                , timeout = Nothing
                , tracker = Nothing
                }

        Nothing ->
            SimulatedEffect.Cmd.none


catalogueResponseDecoder : Decode.Decoder CatalogueResponse
catalogueResponseDecoder =
    Decode.map4 CatalogueResponse
        (Decode.field "books" (Decode.list bookDecoder))
        (Decode.field "total" Decode.int)
        (Decode.field "page" Decode.int)
        (Decode.field "per_page" Decode.int)



-- JSON HELPERS


sampleCatalogueJson : String
sampleCatalogueJson =
    Encode.encode 0
        (Encode.object
            [ ( "books"
              , Encode.list identity
                    [ bookJson "book-1" "The Great Gatsby" "F. Scott Fitzgerald" [ "Fiction", "Classic" ]
                    , bookJson "book-2" "1984" "George Orwell" [ "Fiction", "Dystopia" ]
                    ]
              )
            , ( "total", Encode.int 2 )
            , ( "page", Encode.int 1 )
            , ( "per_page", Encode.int 24 )
            ]
        )


emptyCatalogueJson : String
emptyCatalogueJson =
    Encode.encode 0
        (Encode.object
            [ ( "books", Encode.list identity [] )
            , ( "total", Encode.int 0 )
            , ( "page", Encode.int 1 )
            , ( "per_page", Encode.int 24 )
            ]
        )


bookJson : String -> String -> String -> List String -> Encode.Value
bookJson id title authorName subjects =
    Encode.object
        [ ( "id", Encode.string id )
        , ( "isbn", Encode.string "9780000000000" )
        , ( "title", Encode.string title )
        , ( "author"
          , Encode.object
                [ ( "id", Encode.string ("author-" ++ id) )
                , ( "name", Encode.string authorName )
                ]
          )
        , ( "subjects", Encode.list Encode.string subjects )
        , ( "visibility_tier", Encode.string "public" )
        ]



-- TESTS


loadAndDisplayBooks : Test
loadAndDisplayBooks =
    test "load_books: init fetches catalogue -> renders book cards" <|
        \() ->
            startCatalogue
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/catalogue?sort=title&page=1"
                    sampleCatalogueJson
                |> ProgramTest.ensureViewHas
                    [ Selector.text "The Great Gatsby" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "1984" ]


showsLoadingState : Test
showsLoadingState =
    test "loading_state: shows loading message before data arrives" <|
        \() ->
            startCatalogue
                |> ProgramTest.expectViewHas
                    [ Selector.text "Loading catalogue..." ]


showsErrorState : Test
showsErrorState =
    test "error_state: shows error message on HTTP failure" <|
        \() ->
            startCatalogue
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/catalogue?sort=title&page=1"
                    Http.NetworkError_
                |> ProgramTest.expectViewHas
                    [ Selector.text "Failed to load the catalogue. Please try again." ]


showsEmptyState : Test
showsEmptyState =
    test "empty_state: shows message when no books match" <|
        \() ->
            startCatalogue
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/catalogue?sort=title&page=1"
                    emptyCatalogueJson
                |> ProgramTest.expectViewHas
                    [ Selector.text "No books found matching your criteria." ]


searchTriggersDebounce : Test
searchTriggersDebounce =
    test "search_debounce: type query -> advance past debounce -> new results fetched" <|
        \() ->
            startCatalogue
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/catalogue?sort=title&page=1"
                    sampleCatalogueJson
                |> ProgramTest.update (SearchChanged "gatsby")
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Loading catalogue..." ]
                |> ProgramTest.advanceTime 300
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/catalogue?sort=title&page=1&search=gatsby"
                    sampleCatalogueJson
                |> ProgramTest.expectViewHas
                    [ Selector.text "The Great Gatsby" ]


sortChangeFetchesNewData : Test
sortChangeFetchesNewData =
    test "sort_change: changing sort fetches new data" <|
        \() ->
            startCatalogue
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/catalogue?sort=title&page=1"
                    sampleCatalogueJson
                |> ProgramTest.update (SortChanged "recent")
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Loading catalogue..." ]
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/catalogue?sort=recent&page=1"
                    sampleCatalogueJson
                |> ProgramTest.expectViewHas
                    [ Selector.text "The Great Gatsby" ]


rendersAgeGatedBooksWithNullAuthor : Test
rendersAgeGatedBooksWithNullAuthor =
    test "age_gated_null_author: renders books with age_gated tier and null author" <|
        \() ->
            let
                catalogueWithAgeGatedAndNullAuthor =
                    Encode.encode 0
                        (Encode.object
                            [ ( "books"
                              , Encode.list identity
                                    [ bookJson "book-1" "Normal Book" "Some Author" [ "Fiction" ]
                                    , ageGatedBookJson
                                    , nullAuthorBookJson
                                    ]
                              )
                            , ( "total", Encode.int 3 )
                            , ( "page", Encode.int 1 )
                            , ( "per_page", Encode.int 24 )
                            ]
                        )
            in
            startCatalogue
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/catalogue?sort=title&page=1"
                    catalogueWithAgeGatedAndNullAuthor
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Age Gated Book" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Authorless Book" ]


ageGatedBookJson : Encode.Value
ageGatedBookJson =
    Encode.object
        [ ( "id", Encode.string "book-ag" )
        , ( "isbn", Encode.string "9780000000001" )
        , ( "title", Encode.string "Age Gated Book" )
        , ( "author"
          , Encode.object
                [ ( "id", Encode.string "author-ag" )
                , ( "name", Encode.string "Mature Author" )
                ]
          )
        , ( "subjects", Encode.list Encode.string [] )
        , ( "visibility_tier", Encode.string "age_gated" )
        ]


nullAuthorBookJson : Encode.Value
nullAuthorBookJson =
    Encode.object
        [ ( "id", Encode.string "book-na" )
        , ( "isbn", Encode.string "9780000000002" )
        , ( "title", Encode.string "Authorless Book" )
        , ( "author", Encode.null )
        , ( "subjects", Encode.list Encode.string [] )
        , ( "visibility_tier", Encode.string "public" )
        ]
