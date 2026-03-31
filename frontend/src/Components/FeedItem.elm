module Components.FeedItem exposing (view)

import Html exposing (Html, a, div, text)
import Html.Attributes exposing (class, href)
import Types.FeedItem exposing (FeedItem(..))


view : FeedItem -> Html msg
view feedItem =
    case feedItem of
        PlacementCreated item ->
            div [ class "feed-item feed-item--placement" ]
                [ div [ class "feed-item__user" ] [ text item.userDisplayName ]
                , div [ class "feed-item__content" ]
                    [ text ("“" ++ item.bookTitle ++ "” added to their shelf") ]
                , div [ class "feed-item__time" ] [ text item.occurredAt ]
                ]

        BlogPost item ->
            div [ class "feed-item feed-item--blog-post" ]
                [ div [ class "feed-item__user" ] [ text item.userDisplayName ]
                , div [ class "feed-item__content" ]
                    [ text "published “"
                    , a [ href ("/blog/" ++ item.postId) ] [ text item.postTitle ]
                    , text "”"
                    ]
                , div [ class "feed-item__time" ] [ text item.occurredAt ]
                ]
