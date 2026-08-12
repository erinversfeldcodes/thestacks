module Components.AuthorCard exposing (view)

{-| Author enrichment card component.

Displays author information, website link, latest RSS post,
and upcoming event count. Since the API does not yet return
RSS or event data, those sections show "Coming soon" stubs.

-}

import Api exposing (AuthorEvent)
import Html exposing (Html, a, div, h3, li, p, section, span, text, ul)
import Html.Attributes exposing (attribute, class, href, id, rel, target)
import Types.Book exposing (Author)
import Util.TestId exposing (testId)


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
view : Maybe Author -> Maybe AuthorEnrichment -> Maybe (List AuthorEvent) -> Html msg
view maybeAuthor maybeEnrichment maybeEvents =
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
                        , viewEvents maybeEvents
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


{-| The author's bookstore events (item 4), live from
`GET /api/authors/:id/events`.

`Nothing` = not fetched (or the fetch failed): the honest "coming soon" stub —
never "no events", which would be a claim we haven't earned. `Just []` = we
looked, and the author has none listed. A dateless event links to the shop's
own page instead of pretending to a date.

-}
viewEvents : Maybe (List AuthorEvent) -> Html msg
viewEvents maybeEvents =
    case maybeEvents of
        Just [] ->
            div [ class "book-detail__author-events stub-notice" ]
                [ text "No listed events" ]

        Just events ->
            div [ class "book-detail__author-events", testId "author-events" ]
                [ ul [ class "book-detail__author-events-list" ]
                    (List.map viewEvent events)
                ]

        Nothing ->
            div [ class "book-detail__author-events stub-notice" ]
                [ text "Events coming soon" ]


viewEvent : AuthorEvent -> Html msg
viewEvent event =
    li [ class "book-detail__author-event", testId "author-event" ]
        [ span [ class "book-detail__author-event-title" ] [ text event.title ]
        , span [ class "book-detail__author-event-where" ]
            [ text (eventWhere event) ]
        , case event.url of
            Just url ->
                a
                    [ class "book-detail__author-event-link"
                    , href url
                    , target "_blank"
                    , rel "noopener noreferrer"
                    ]
                    [ text "Details on the shop's page" ]

            Nothing ->
                text ""
        ]


eventWhere : AuthorEvent -> String
eventWhere event =
    case ( event.eventDate, event.storeName ) of
        ( Just date, Just store ) ->
            String.left 10 date ++ " — " ++ store

        ( Just date, Nothing ) ->
            String.left 10 date

        ( Nothing, Just store ) ->
            store

        ( Nothing, Nothing ) ->
            ""
