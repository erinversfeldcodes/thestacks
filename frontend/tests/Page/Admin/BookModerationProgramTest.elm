module Page.Admin.BookModerationProgramTest exposing (suite)

{-| Program tests for Page.Admin.BookModeration (owner age-gate surface).

Drives the page through elm-program-test: loading the book list and toggling
a row's age gate (which must fire the admin PUT).

-}

import Api
import Dict
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Page.Admin.BookModeration as BM
import ProgramTest exposing (ProgramDefinition, SimulatedEffect)
import SimulatedEffect.Cmd
import SimulatedEffect.Http
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector


bmInitEffect : Maybe String -> SimulatedEffect BM.Msg
bmInitEffect maybeToken =
    case maybeToken of
        Just token ->
            SimulatedEffect.Http.request
                { method = "GET"
                , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                , url = "/api/admin/books?page=1"
                , body = SimulatedEffect.Http.emptyBody
                , expect = SimulatedEffect.Http.expectJson BM.BooksReceived Api.adminBooksResponseDecoder
                , timeout = Nothing
                , tracker = Nothing
                }

        Nothing ->
            SimulatedEffect.Cmd.none


bmEffects : BM.Msg -> Maybe String -> SimulatedEffect BM.Msg
bmEffects msg maybeToken =
    case ( msg, maybeToken ) of
        ( BM.ToggleAgeGate bookId newAgeGated, Just token ) ->
            SimulatedEffect.Http.request
                { method = "PUT"
                , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                , url = "/api/admin/books/" ++ bookId ++ "/age-gate"
                , body =
                    SimulatedEffect.Http.jsonBody
                        (Encode.object [ ( "age_gated", Encode.bool newAgeGated ) ])
                , expect =
                    SimulatedEffect.Http.expectJson (BM.AgeGateCompleted bookId)
                        (Decode.field "book" Api.adminBookDecoder)
                , timeout = Nothing
                , tracker = Nothing
                }

        _ ->
            SimulatedEffect.Cmd.none


program : Maybe String -> ProgramDefinition () BM.Model BM.Msg (SimulatedEffect BM.Msg)
program maybeToken =
    ProgramTest.createElement
        { init =
            \() ->
                let
                    ( model, _ ) =
                        BM.init maybeToken
                in
                ( model, bmInitEffect maybeToken )
        , update =
            \msg model ->
                let
                    ( newModel, _, _ ) =
                        BM.update msg model maybeToken
                in
                ( newModel, bmEffects msg maybeToken )
        , view = BM.view
        }
        |> ProgramTest.withSimulatedEffects identity


encodeBookJson : String -> String -> String -> String -> Encode.Value
encodeBookJson id title author tier =
    Encode.object
        [ ( "id", Encode.string id )
        , ( "title", Encode.string title )
        , ( "author", Encode.string author )
        , ( "visibility_tier", Encode.string tier )
        , ( "isbn", Encode.null )
        , ( "cover_image_url", Encode.null )
        ]


booksListResponse : List Encode.Value -> Http.Response String
booksListResponse books =
    Http.GoodStatus_
        { url = "/api/admin/books?page=1"
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        (Encode.encode 0
            (Encode.object
                [ ( "books", Encode.list identity books )
                , ( "total", Encode.int (List.length books) )
                , ( "page", Encode.int 1 )
                , ( "per_page", Encode.int 50 )
                ]
            )
        )


bookUpdateResponse : String -> Encode.Value -> Http.Response String
bookUpdateResponse bookId book =
    Http.GoodStatus_
        { url = "/api/admin/books/" ++ bookId ++ "/age-gate"
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        (Encode.encode 0 (Encode.object [ ( "book", book ) ]))


suite : Test
suite =
    describe "Page.Admin.BookModeration (ProgramTest)"
        [ loadsList
        , togglesRow
        ]


loadsList : Test
loadsList =
    test "loads and renders the book list with tiers" <|
        \() ->
            ProgramTest.start () (program (Just "admin-token"))
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/admin/books?page=1"
                    (booksListResponse
                        [ encodeBookJson "b1" "Dune" "Frank Herbert" "public"
                        , encodeBookJson "b2" "Adult Title" "Some Author" "age_gated"
                        ]
                    )
                |> ProgramTest.ensureViewHas [ Selector.text "Dune" ]
                |> ProgramTest.ensureViewHas [ Selector.text "Adult Title" ]
                |> ProgramTest.expectViewHas [ Selector.text "age_gated" ]


togglesRow : Test
togglesRow =
    test "toggling a public book fires the admin PUT and flips the tier to age_gated" <|
        \() ->
            ProgramTest.start () (program (Just "admin-token"))
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/admin/books?page=1"
                    (booksListResponse
                        [ encodeBookJson "b1" "Dune" "Frank Herbert" "public" ]
                    )
                |> ProgramTest.ensureViewHas [ Selector.text "Mark age-gated" ]
                |> ProgramTest.clickButton "Mark age-gated"
                |> ProgramTest.simulateHttpResponse "PUT"
                    "/api/admin/books/b1/age-gate"
                    (bookUpdateResponse "b1"
                        (encodeBookJson "b1" "Dune" "Frank Herbert" "age_gated")
                    )
                |> ProgramTest.expectViewHas [ Selector.text "Un-gate" ]
