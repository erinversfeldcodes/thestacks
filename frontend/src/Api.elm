module Api exposing
    ( AuthResponse
    , BookDetailResponse
    , CatalogueResponse
    , PlacementSummary
    , PollResponse
    , PollStatus(..)
    , getBook
    , getBookshelf
    , getCatalogue
    , getUserPlacements
    , login
    , moveBook
    , placeBook
    , pollUploadStatus
    , register
    , removeBook
    , saveConsent
    , searchBooks
    , updateAgeVerification
    , uploadImage
    )

import File exposing (File)
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Types.Book exposing (Book, bookDecoder)
import Types.Placement exposing (Placement, placementDecoder)
import Url.Builder


baseUrl : String
baseUrl =
    ""


type alias AuthResponse =
    { token : String
    , userId : String
    , email : String
    , displayName : String
    }


authResponseDecoder : Decoder AuthResponse
authResponseDecoder =
    Decode.map4 AuthResponse
        (Decode.field "token" Decode.string)
        (Decode.at [ "user", "id" ] Decode.string)
        (Decode.at [ "user", "email" ] Decode.string)
        (Decode.at [ "user", "display_name" ] Decode.string)


{-| The identification status of an uploaded image.
Fails loudly on unknown values rather than silently falling through.
-}
type PollStatus
    = Pending
    | Resolved
    | Rejected


pollStatusDecoder : Decoder PollStatus
pollStatusDecoder =
    Decode.string
        |> Decode.andThen
            (\s ->
                case s of
                    "pending" ->
                        Decode.succeed Pending

                    "resolved" ->
                        Decode.succeed Resolved

                    "rejected" ->
                        Decode.succeed Rejected

                    _ ->
                        Decode.fail ("Unknown upload status: " ++ s)
            )


{-| Response from GET /api/upload/:image\_id/status.
bookId is present only when status is Resolved and a book was identified.
isDuplicate is true when the identified book is already on one of the user's shelves.
-}
type alias PollResponse =
    { imageId : String
    , status : PollStatus
    , bookId : Maybe String
    , bookIds : List String
    , rejectionReason : Maybe String
    , isDuplicate : Maybe Bool
    }


pollResponseDecoder : Decoder PollResponse
pollResponseDecoder =
    Decode.map6 PollResponse
        (Decode.field "image_id" Decode.string)
        (Decode.field "status" pollStatusDecoder)
        (Decode.maybe (Decode.field "book_id" Decode.string))
        (Decode.field "book_ids" (Decode.list Decode.string) |> Decode.maybe |> Decode.map (Maybe.withDefault []))
        (Decode.maybe (Decode.field "rejection_reason" Decode.string))
        (Decode.maybe (Decode.field "is_duplicate" Decode.bool))


register :
    { email : String, password : String, displayName : String }
    -> (Result Http.Error AuthResponse -> msg)
    -> Cmd msg
register body toMsg =
    Http.post
        { url = baseUrl ++ "/api/auth/register"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "email", Encode.string body.email )
                    , ( "password", Encode.string body.password )
                    , ( "display_name", Encode.string body.displayName )
                    ]
                )
        , expect = Http.expectJson toMsg authResponseDecoder
        }


login :
    { email : String, password : String }
    -> (Result Http.Error AuthResponse -> msg)
    -> Cmd msg
login body toMsg =
    Http.post
        { url = baseUrl ++ "/api/auth/login"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "email", Encode.string body.email )
                    , ( "password", Encode.string body.password )
                    ]
                )
        , expect = Http.expectJson toMsg authResponseDecoder
        }


{-| POST /api/upload — returns the image\_id from the 202 accepted response.
-}
uploadImage :
    File
    -> String
    -> (Result Http.Error String -> msg)
    -> Cmd msg
uploadImage file token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/upload"
        , body = Http.multipartBody [ Http.filePart "image" file ]
        , expect = Http.expectJson toMsg (Decode.field "image_id" Decode.string)
        , timeout = Nothing
        , tracker = Nothing
        }


{-| GET /api/upload/:image\_id/status — poll for the identification result.
-}
pollUploadStatus :
    String
    -> String
    -> (Result Http.Error PollResponse -> msg)
    -> Cmd msg
pollUploadStatus imageId token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/upload/" ++ imageId ++ "/status"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg pollResponseDecoder
        , timeout = Nothing
        , tracker = Nothing
        }


{-| Response from GET /api/books/:id — book with optional placement data.
-}
type alias BookDetailResponse =
    { book : Book
    , placement : Maybe Placement
    }


bookDetailResponseDecoder : Decoder BookDetailResponse
bookDetailResponseDecoder =
    Decode.map2 BookDetailResponse
        (Decode.field "book" bookDecoder)
        (Decode.maybe (Decode.field "placement" placementDecoder))


{-| Lightweight placement summary for duplicate detection.
-}
type alias PlacementSummary =
    { bookId : String
    , bookshelfName : String
    }


placementSummaryDecoder : Decoder PlacementSummary
placementSummaryDecoder =
    Decode.map2 PlacementSummary
        (Decode.field "book_id" Decode.string)
        (Decode.field "bookshelf_name" Decode.string)


getBook :
    String
    -> Maybe String
    -> (Result Http.Error BookDetailResponse -> msg)
    -> Cmd msg
getBook bookId maybeToken toMsg =
    Http.request
        { method = "GET"
        , headers =
            case maybeToken of
                Just token ->
                    [ Http.header "Authorization" ("Bearer " ++ token) ]

                Nothing ->
                    []
        , url = baseUrl ++ "/api/books/" ++ bookId
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg bookDetailResponseDecoder
        , timeout = Nothing
        , tracker = Nothing
        }


searchBooks :
    String
    -> String
    -> (Result Http.Error (List Book) -> msg)
    -> Cmd msg
searchBooks query token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = Url.Builder.crossOrigin baseUrl [ "api", "books", "search" ] [ Url.Builder.string "q" query ]
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.list bookDecoder)
        , timeout = Nothing
        , tracker = Nothing
        }


getBookshelf :
    String
    -> String
    -> (Result Http.Error (List Placement) -> msg)
    -> Cmd msg
getBookshelf shelfName token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/bookshelves/" ++ shelfName
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "placements" (Decode.list placementDecoder))
        , timeout = Nothing
        , tracker = Nothing
        }


moveBook :
    String
    -> String
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
moveBook placementId targetBookshelf token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/placements/" ++ placementId ++ "/move"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "bookshelf", Encode.string targetBookshelf ) ]
                )
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
        , tracker = Nothing
        }


removeBook :
    String
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
removeBook placementId token toMsg =
    Http.request
        { method = "DELETE"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/placements/" ++ placementId
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
        , tracker = Nothing
        }


{-| POST /api/gdpr/consent — save the user's analytics consent preference.
-}
saveConsent :
    Bool
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
saveConsent consent token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/gdpr/consent"
        , body = Http.jsonBody (Encode.object [ ( "consent", Encode.bool consent ) ])
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
        , tracker = Nothing
        }


{-| PUT /api/settings/age\_verification — save the user's age verification status.
-}
updateAgeVerification :
    Bool
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
updateAgeVerification verified token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/settings/age_verification"
        , body = Http.jsonBody (Encode.object [ ( "age_verified", Encode.bool verified ) ])
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
        , tracker = Nothing
        }


{-| Response from GET /api/catalogue — paginated book list.
-}
type alias CatalogueResponse =
    { books : List Book
    , total : Int
    , page : Int
    , perPage : Int
    }


catalogueResponseDecoder : Decoder CatalogueResponse
catalogueResponseDecoder =
    Decode.map4 CatalogueResponse
        (Decode.field "books" (Decode.list bookDecoder))
        (Decode.field "total" Decode.int)
        (Decode.field "page" Decode.int)
        (Decode.field "per_page" Decode.int)


{-| POST /api/bookshelves/:name/placements — place a book on a bookshelf.
-}
placeBook :
    String
    -> String
    -> String
    -> (Result Http.Error Placement -> msg)
    -> Cmd msg
placeBook bookshelfName bookId token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/bookshelves/" ++ bookshelfName ++ "/placements"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "book_id", Encode.string bookId ) ]
                )
        , expect = Http.expectJson toMsg (Decode.field "placement" placementDecoder)
        , timeout = Nothing
        , tracker = Nothing
        }


{-| GET /api/placements/mine — fetch summary of user's active placements.
-}
getUserPlacements :
    String
    -> (Result Http.Error (List PlacementSummary) -> msg)
    -> Cmd msg
getUserPlacements token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/placements/mine"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "placements" (Decode.list placementSummaryDecoder))
        , timeout = Nothing
        , tracker = Nothing
        }


{-| GET /api/catalogue — fetch paginated book catalogue.
-}
getCatalogue :
    { search : Maybe String
    , subject : Maybe String
    , sort : String
    , page : Int
    }
    -> (Result Http.Error CatalogueResponse -> msg)
    -> Cmd msg
getCatalogue params toMsg =
    let
        queryParams =
            [ Just (Url.Builder.string "sort" params.sort)
            , Just (Url.Builder.int "page" params.page)
            , params.search |> Maybe.map (Url.Builder.string "search")
            , params.subject |> Maybe.map (Url.Builder.string "subject")
            ]
                |> List.filterMap identity
    in
    Http.request
        { method = "GET"
        , headers = []
        , url = Url.Builder.absolute [ "api", "catalogue" ] queryParams
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg catalogueResponseDecoder
        , timeout = Nothing
        , tracker = Nothing
        }
