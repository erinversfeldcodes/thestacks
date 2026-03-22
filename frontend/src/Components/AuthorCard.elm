module Components.AuthorCard exposing (view)

{-| Author enrichment card component.

Displays author information, website link, latest RSS post,
and upcoming event count. Since the API does not yet return
RSS or event data, those sections show "Coming soon" stubs.

-}

import Html exposing (Html, a, div, h3, p, section, span, text)
import Html.Attributes exposing (attribute, class, href, id, rel, target)
import Types.Book exposing (Author)


{-| An RSS post from the author's feed.
-}
type alias RssPost =
    { title : String
    , date : String
    , excerpt : String
    , url : String
    }


{-| Enrichment data for the author section.
-}
type alias AuthorEnrichment =
    { latestPost : Maybe RssPost
    , upcomingEventsCount : Int
    }


{-| Render the author card section.

Takes the Author from the Book type and optional enrichment data.
When enrichment is Nothing, stubs are shown for RSS and events.

-}
view : Maybe Author -> Maybe AuthorEnrichment -> Html msg
view maybeAuthor maybeEnrichment =
    case maybeAuthor of
        Nothing ->
            section
                [ class "book-detail__section book-detail__author-card"
                , attribute "role" "region"
                , attribute "aria-labelledby" "section-author"
                ]
                [ h3 [ class "book-detail__section-title", id "section-author" ]
                    [ text "The Author" ]
                , p [ class "book-detail__author-empty" ]
                    [ text "Author information unavailable" ]
                ]

        Just author ->
            section
                [ class "book-detail__section book-detail__author-card"
                , attribute "role" "region"
                , attribute "aria-labelledby" "section-author"
                ]
                [ h3 [ class "book-detail__section-title", id "section-author" ]
                    [ text "The Author" ]
                , div [ class "book-detail__author-info" ]
                    [ div [ class "book-detail__author-avatar" ]
                        [ span [ class "book-detail__author-initial" ]
                            [ text (String.left 1 author.name) ]
                        ]
                    , div [ class "book-detail__author-details" ]
                        [ p [ class "book-detail__author-name" ] [ text author.name ]
                        , viewBio author.bio
                        , viewWebsite author.website
                        , viewRssPost maybeEnrichment
                        , viewEvents maybeEnrichment
                        ]
                    ]
                ]


viewBio : Maybe String -> Html msg
viewBio maybeBio =
    case maybeBio of
        Just bio ->
            p [ class "book-detail__author-bio" ] [ text bio ]

        Nothing ->
            text ""


viewWebsite : Maybe String -> Html msg
viewWebsite maybeUrl =
    case maybeUrl of
        Just url ->
            a [ class "book-detail__author-link", href url, target "_blank", rel "noopener noreferrer" ]
                [ text "Website" ]

        Nothing ->
            text ""


viewRssPost : Maybe AuthorEnrichment -> Html msg
viewRssPost maybeEnrichment =
    case maybeEnrichment of
        Just enrichment ->
            case enrichment.latestPost of
                Just post ->
                    div [ class "book-detail__author-rss" ]
                        [ p [ class "book-detail__author-rss-title" ]
                            [ text post.title ]
                        , p [ class "book-detail__author-rss-date" ]
                            [ text post.date ]
                        , p [ class "book-detail__author-rss-excerpt" ]
                            [ text post.excerpt ]
                        , a
                            [ class "book-detail__author-rss-link"
                            , href post.url
                            , target "_blank"
                            , rel "noopener noreferrer"
                            ]
                            [ text "Read more" ]
                        ]

                Nothing ->
                    div [ class "book-detail__author-rss stub-notice" ]
                        [ text "No recent posts" ]

        Nothing ->
            div [ class "book-detail__author-rss stub-notice" ]
                [ text "RSS feed coming soon" ]


viewEvents : Maybe AuthorEnrichment -> Html msg
viewEvents maybeEnrichment =
    case maybeEnrichment of
        Just enrichment ->
            if enrichment.upcomingEventsCount > 0 then
                div [ class "book-detail__author-events" ]
                    [ text
                        (String.fromInt enrichment.upcomingEventsCount
                            ++ " upcoming event"
                            ++ (if enrichment.upcomingEventsCount == 1 then
                                    ""

                                else
                                    "s"
                               )
                            ++ " at bookstores near you"
                        )
                    ]

            else
                div [ class "book-detail__author-events stub-notice" ]
                    [ text "No upcoming events" ]

        Nothing ->
            div [ class "book-detail__author-events stub-notice" ]
                [ text "Events coming soon" ]
