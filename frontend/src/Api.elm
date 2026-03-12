module Api exposing
    ( AuthResponse
    , PollResponse
    , PollStatus(..)
    , getBook
    , getBookshelf
    , login
    , moveBook
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


getBook :
    String
    -> String
    -> (Result Http.Error Book -> msg)
    -> Cmd msg
getBook bookId token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/books/" ++ bookId
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "book" bookDecoder)
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
