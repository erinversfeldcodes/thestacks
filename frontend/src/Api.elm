module Api exposing
    ( AuthResponse
    , BookDetailResponse
    , CatalogueResponse
    , ListingParams
    , MergeFormatResponse
    , NotificationPreferences
    , PlacementSummary
    , PollResponse
    , PollStatus(..)
    , activateListing
    , confirmAssociation
    , createBlogPost
    , createListing
    , deactivateListing
    , dismissAssociation
    , getBlogPost
    , getBlogPosts
    , getBook
    , getBookshelf
    , getCatalogue
    , getListings
    , getMyListings
    , getMyPlacements
    , getUserPlacements
    , login
    , logout
    , lookupByIsbn
    , mergeFormat
    , moveBook
    , placeBook
    , pollUploadStatus
    , publishBlogPost
    , register
    , removeBook
    , saveConsent
    , searchBooks
    , soldListing
    , updateAgeVerification
    , updateBlogPost
    , updateLocation
    , updateNotifications
    , updatePassword
    , updateProfile
    , updateProfileVisibility
    , updateShelfVisibility
    , uploadImage
    )

import File exposing (File)
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Types.BlogPost exposing (BlogPost, BlogPostSummary, blogPostDecoder, blogPostSummaryDecoder)
import Types.Book exposing (Book, Edition, bookDecoder, editionDecoder)
import Types.Listing exposing (Listing, ListingsResponse, listingDecoder, listingsResponseDecoder)
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


{-| POST /api/auth/logout — invalidate the current session.
-}
logout :
    String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
logout token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/auth/logout"
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
        , tracker = Nothing
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


{-| GET /api/books/isbn/:isbn — look up a book by ISBN.
-}
lookupByIsbn :
    String
    -> String
    -> (Result Http.Error BookDetailResponse -> msg)
    -> Cmd msg
lookupByIsbn isbn token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/books/isbn/" ++ isbn
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg bookDetailResponseDecoder
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


{-| PUT /api/settings/profile — update display name, email, and website URL.
-}
updateProfile :
    { displayName : String, email : String, websiteUrl : String }
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
updateProfile body token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/settings/profile"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "display_name", Encode.string body.displayName )
                    , ( "email", Encode.string body.email )
                    , ( "website_url", Encode.string body.websiteUrl )
                    ]
                )
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
        , tracker = Nothing
        }


{-| PUT /api/settings/location — update the user's location.
-}
updateLocation :
    { countryCode : String, city : String }
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
updateLocation body token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = "/api/settings/location"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "country_code", Encode.string body.countryCode )
                    , ( "city", Encode.string body.city )
                    ]
                )
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
        , tracker = Nothing
        }


{-| PUT /api/settings/password — change the user's password.
-}
updatePassword :
    { currentPassword : String, newPassword : String }
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
updatePassword body token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/settings/password"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "current_password", Encode.string body.currentPassword )
                    , ( "new_password", Encode.string body.newPassword )
                    ]
                )
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
        , tracker = Nothing
        }


{-| Notification preference flags.
-}
type alias NotificationPreferences =
    { priceDrops : Bool
    , newReviews : Bool
    , authorUpdates : Bool
    , eventAlerts : Bool
    }


{-| PUT /api/settings/notifications — update notification preferences.
-}
updateNotifications :
    NotificationPreferences
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
updateNotifications prefs token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/settings/notifications"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "price_drops", Encode.bool prefs.priceDrops )
                    , ( "new_reviews", Encode.bool prefs.newReviews )
                    , ( "author_updates", Encode.bool prefs.authorUpdates )
                    , ( "event_alerts", Encode.bool prefs.eventAlerts )
                    ]
                )
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
        , tracker = Nothing
        }


{-| Response from POST /api/books/:id/merge-format — the new edition.
-}
type alias MergeFormatResponse =
    { edition : Edition
    }


mergeFormatResponseDecoder : Decoder MergeFormatResponse
mergeFormatResponseDecoder =
    Decode.map MergeFormatResponse
        (Decode.field "edition" editionDecoder)


{-| POST /api/books/:id/merge-format — add a new edition (ISBN/format) to an existing book.
-}
mergeFormat :
    String
    -> { isbn : String, formatLabel : String }
    -> String
    -> (Result Http.Error MergeFormatResponse -> msg)
    -> Cmd msg
mergeFormat bookId body token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/books/" ++ bookId ++ "/merge-format"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "isbn", Encode.string body.isbn )
                    , ( "format_label", Encode.string body.formatLabel )
                    ]
                )
        , expect = Http.expectJson toMsg mergeFormatResponseDecoder
        , timeout = Nothing
        , tracker = Nothing
        }



-- MARKETPLACE LISTINGS


{-| Parameters for creating a new listing.
-}
type alias ListingParams =
    { placementId : String
    , condition : String
    , pricingMode : String
    , priceZar : Maybe Int
    , contactInfo : String
    , description : String
    }


{-| GET /api/listings — fetch active marketplace listings.
-}
getListings :
    Maybe String
    -> (Result Http.Error ListingsResponse -> msg)
    -> Cmd msg
getListings maybeToken toMsg =
    Http.request
        { method = "GET"
        , headers =
            case maybeToken of
                Just token ->
                    [ Http.header "Authorization" ("Bearer " ++ token) ]

                Nothing ->
                    []
        , url = baseUrl ++ "/api/listings"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg listingsResponseDecoder
        , timeout = Nothing
        , tracker = Nothing
        }


{-| GET /api/listings/mine — fetch the current user's listings.
-}
getMyListings :
    String
    -> (Result Http.Error ListingsResponse -> msg)
    -> Cmd msg
getMyListings token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/listings/mine"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg listingsResponseDecoder
        , timeout = Nothing
        , tracker = Nothing
        }


{-| POST /api/listings — create a new listing.
-}
createListing :
    ListingParams
    -> String
    -> (Result Http.Error Listing -> msg)
    -> Cmd msg
createListing params token toMsg =
    let
        priceField =
            case params.priceZar of
                Just price ->
                    [ ( "price_zar", Encode.int price ) ]

                Nothing ->
                    []
    in
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/listings"
        , body =
            Http.jsonBody
                (Encode.object
                    ([ ( "placement_id", Encode.string params.placementId )
                     , ( "condition", Encode.string params.condition )
                     , ( "pricing_mode", Encode.string params.pricingMode )
                     , ( "contact_info", Encode.string params.contactInfo )
                     , ( "description", Encode.string params.description )
                     ]
                        ++ priceField
                    )
                )
        , expect = Http.expectJson toMsg (Decode.field "listing" listingDecoder)
        , timeout = Nothing
        , tracker = Nothing
        }


{-| PUT /api/listings/:id/activate — activate a draft listing.
-}
activateListing :
    String
    -> String
    -> (Result Http.Error Listing -> msg)
    -> Cmd msg
activateListing listingId token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/listings/" ++ listingId ++ "/activate"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "listing" listingDecoder)
        , timeout = Nothing
        , tracker = Nothing
        }


{-| PUT /api/listings/:id/deactivate — deactivate an active listing.
-}
deactivateListing :
    String
    -> String
    -> (Result Http.Error Listing -> msg)
    -> Cmd msg
deactivateListing listingId token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/listings/" ++ listingId ++ "/deactivate"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "listing" listingDecoder)
        , timeout = Nothing
        , tracker = Nothing
        }


{-| PUT /api/listings/:id/sold — mark a listing as sold.
-}
soldListing :
    String
    -> String
    -> (Result Http.Error Listing -> msg)
    -> Cmd msg
soldListing listingId token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/listings/" ++ listingId ++ "/sold"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "listing" listingDecoder)
        , timeout = Nothing
        , tracker = Nothing
        }


{-| GET /api/placements/mine — fetch the current user's placements with book data.
Used by the create listing form to select which book to list.
-}
getMyPlacements :
    String
    -> (Result Http.Error (List Placement) -> msg)
    -> Cmd msg
getMyPlacements token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/placements/mine"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "placements" (Decode.list placementDecoder))
        , timeout = Nothing
        , tracker = Nothing
        }



-- BLOG


{-| GET /api/blog/posts — fetch all blog posts.
-}
getBlogPosts :
    Maybe String
    -> (Result Http.Error (List BlogPostSummary) -> msg)
    -> Cmd msg
getBlogPosts maybeToken toMsg =
    Http.request
        { method = "GET"
        , headers =
            case maybeToken of
                Just token ->
                    [ Http.header "Authorization" ("Bearer " ++ token) ]

                Nothing ->
                    []
        , url = baseUrl ++ "/api/blog/posts"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "posts" (Decode.list blogPostSummaryDecoder))
        , timeout = Nothing
        , tracker = Nothing
        }


{-| GET /api/blog/posts/:id — fetch a single blog post.
-}
getBlogPost :
    String
    -> Maybe String
    -> (Result Http.Error BlogPost -> msg)
    -> Cmd msg
getBlogPost postId maybeToken toMsg =
    Http.request
        { method = "GET"
        , headers =
            case maybeToken of
                Just token ->
                    [ Http.header "Authorization" ("Bearer " ++ token) ]

                Nothing ->
                    []
        , url = baseUrl ++ "/api/blog/posts/" ++ postId
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "post" blogPostDecoder)
        , timeout = Nothing
        , tracker = Nothing
        }


{-| POST /api/blog/posts — create a new blog post. Returns the new post ID.
-}
createBlogPost :
    { title : String, body : String, visibility : String }
    -> String
    -> (Result Http.Error String -> msg)
    -> Cmd msg
createBlogPost postData token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/blog/posts"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "title", Encode.string postData.title )
                    , ( "body", Encode.string postData.body )
                    , ( "visibility", Encode.string postData.visibility )
                    ]
                )
        , expect = Http.expectJson toMsg (Decode.at [ "post", "id" ] Decode.string)
        , timeout = Nothing
        , tracker = Nothing
        }


{-| PUT /api/blog/posts/:id — update an existing blog post. Returns the post ID.
-}
updateBlogPost :
    String
    -> { title : String, body : String, visibility : String }
    -> String
    -> (Result Http.Error String -> msg)
    -> Cmd msg
updateBlogPost postId postData token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/blog/posts/" ++ postId
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "title", Encode.string postData.title )
                    , ( "body", Encode.string postData.body )
                    , ( "visibility", Encode.string postData.visibility )
                    ]
                )
        , expect = Http.expectJson toMsg (Decode.at [ "post", "id" ] Decode.string)
        , timeout = Nothing
        , tracker = Nothing
        }


{-| POST /api/blog/posts/:id/publish — publish a blog post.
-}
publishBlogPost :
    String
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
publishBlogPost postId token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/blog/posts/" ++ postId ++ "/publish"
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
        , tracker = Nothing
        }


{-| PUT /api/blog/posts/:post\_id/associations/:id/confirm — confirm a book association.
-}
confirmAssociation :
    String
    -> String
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
confirmAssociation postId associationId token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/blog/posts/" ++ postId ++ "/associations/" ++ associationId ++ "/confirm"
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
        , tracker = Nothing
        }


{-| PUT /api/blog/posts/:post\_id/associations/:id/dismiss — dismiss a book association.
-}
dismissAssociation :
    String
    -> String
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
dismissAssociation postId associationId token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/blog/posts/" ++ postId ++ "/associations/" ++ associationId ++ "/dismiss"
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
        , tracker = Nothing
        }



-- PRIVACY / VISIBILITY


{-| PUT /api/settings/profile\_visibility — update profile visibility.
-}
updateProfileVisibility :
    String
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
updateProfileVisibility visibility token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/settings/profile_visibility"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "visibility", Encode.string visibility ) ]
                )
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
        , tracker = Nothing
        }


{-| PUT /api/bookshelves/:id/visibility — update shelf visibility.
-}
updateShelfVisibility :
    String
    -> String
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
updateShelfVisibility shelfName visibility token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/bookshelves/" ++ shelfName ++ "/visibility"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "visibility", Encode.string visibility ) ]
                )
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
        , tracker = Nothing
        }
