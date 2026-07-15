module Types.FeedItem exposing
    ( FeedItem(..)
    , FeedResponse
    , feedItemUserDisplayName
    , feedItemUserId
    , feedResponseDecoder
    )

import Json.Decode as Decode exposing (Decoder)


type FeedItem
    = PlacementCreated
        { placementId : String
        , bookId : String
        , bookTitle : String
        , bookCoverUrl : Maybe String
        , userId : String
        , userDisplayName : String
        , occurredAt : String
        }
    | BlogPost
        { postId : String
        , postTitle : String
        , postVisibility : String
        , userId : String
        , userDisplayName : String
        , occurredAt : String
        }


type alias FeedResponse =
    { data : List FeedItem
    , nextCursor : Maybe String
    }


{-| The id of the user a feed item is attributed to — used to offer a block
affordance on another member's activity.
-}
feedItemUserId : FeedItem -> String
feedItemUserId item =
    case item of
        PlacementCreated i ->
            i.userId

        BlogPost i ->
            i.userId


{-| The display name of the user a feed item is attributed to (block label).
-}
feedItemUserDisplayName : FeedItem -> String
feedItemUserDisplayName item =
    case item of
        PlacementCreated i ->
            i.userDisplayName

        BlogPost i ->
            i.userDisplayName


feedItemDecoder : Decoder FeedItem
feedItemDecoder =
    Decode.field "type" Decode.string
        |> Decode.andThen
            (\t ->
                case t of
                    "placement_created" ->
                        Decode.map7
                            (\pid bid bt bcu uid udn oat ->
                                PlacementCreated
                                    { placementId = pid
                                    , bookId = bid
                                    , bookTitle = bt
                                    , bookCoverUrl = bcu
                                    , userId = uid
                                    , userDisplayName = udn
                                    , occurredAt = oat
                                    }
                            )
                            (Decode.field "placement_id" Decode.string)
                            (Decode.field "book_id" Decode.string)
                            (Decode.field "book_title" Decode.string)
                            (Decode.field "book_cover_url" (Decode.nullable Decode.string))
                            (Decode.field "user_id" Decode.string)
                            (Decode.field "user_display_name" Decode.string)
                            (Decode.field "occurred_at" Decode.string)

                    "blog_post" ->
                        Decode.map6
                            (\pid pt pv uid udn oat ->
                                BlogPost
                                    { postId = pid
                                    , postTitle = pt
                                    , postVisibility = pv
                                    , userId = uid
                                    , userDisplayName = udn
                                    , occurredAt = oat
                                    }
                            )
                            (Decode.field "post_id" Decode.string)
                            (Decode.field "post_title" Decode.string)
                            (Decode.field "post_visibility" Decode.string)
                            (Decode.field "user_id" Decode.string)
                            (Decode.field "user_display_name" Decode.string)
                            (Decode.field "occurred_at" Decode.string)

                    _ ->
                        Decode.fail ("Unknown feed item type: " ++ t)
            )


feedResponseDecoder : Decoder FeedResponse
feedResponseDecoder =
    Decode.map2 FeedResponse
        (Decode.field "data" (Decode.list feedItemDecoder))
        (Decode.field "next_cursor" (Decode.nullable Decode.string))
