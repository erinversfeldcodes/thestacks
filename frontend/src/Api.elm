module Api exposing
    ( AuthResponse
    , UploadResponse
    , authResponseDecoder
    , getBook
    , getBookshelf
    , login
    , moveBook
    , register
    , removeBook
    , searchBooks
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
    "http://localhost:4000"


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
        (Decode.field "user_id" Decode.string)
        (Decode.field "email" Decode.string)
        (Decode.field "display_name" Decode.string)


type alias UploadResponse =
    { bookId : Maybe String
    , isbn : Maybe String
    , confidence : Float
    , status : String
    }


uploadResponseDecoder : Decoder UploadResponse
uploadResponseDecoder =
    Decode.map4 UploadResponse
        (Decode.maybe (Decode.field "book_id" Decode.string))
        (Decode.maybe (Decode.field "isbn" Decode.string))
        (Decode.field "confidence" Decode.float)
        (Decode.field "status" Decode.string)


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


uploadImage :
    File
    -> String
    -> (Result Http.Error UploadResponse -> msg)
    -> Cmd msg
uploadImage file token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/upload"
        , body = Http.multipartBody [ Http.filePart "image" file ]
        , expect = Http.expectJson toMsg uploadResponseDecoder
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
        , expect = Http.expectJson toMsg bookDecoder
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
