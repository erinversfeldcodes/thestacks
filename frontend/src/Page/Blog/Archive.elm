module Page.Blog.Archive exposing
    ( Model
    , Msg(..)
    , init
    , previewOf
    , update
    , view
    )

import Api
import Components.VisibilityBadge as VisibilityBadge
import Html exposing (Html, a, button, div, h1, h2, li, p, span, text, ul)
import Html.Attributes exposing (class, disabled, href)
import Html.Events exposing (onClick)
import Http
import Navigation.Route as Route exposing (Route(..))
import Types.BlogPost exposing (BlogPostSummary, visibilityToString)
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { posts : RemoteData Http.Error (List BlogPostSummary)
    , isAuthenticated : Bool
    , token : Maybe String

    -- The server's cursor for the next page, `Nothing` once the feed is
    -- exhausted. ⚠️ It is the ONLY end-of-feed signal: the window is read before
    -- visibility is applied, so a page can arrive short — or completely empty —
    -- with posts this reader may read sitting behind it. Stopping on an empty
    -- page would leave that tail unreachable, which is what it used to be.
    , nextCursor : Maybe String
    , loadingMore : Bool
    }


type Msg
    = PostsLoaded (Result Http.Error Api.BlogPostPage)
    | LoadMore


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    ( { posts = Loading
      , isAuthenticated = maybeToken /= Nothing
      , token = maybeToken
      , nextCursor = Nothing
      , loadingMore = False
      }
    , Api.getBlogPosts maybeToken Nothing PostsLoaded
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        PostsLoaded result ->
            case result of
                Ok page ->
                    let
                        -- Append, so a later page extends the archive instead of
                        -- replacing it.
                        combined =
                            case model.posts of
                                Success existing ->
                                    existing ++ page.posts

                                _ ->
                                    page.posts
                    in
                    ( { model
                        | posts = Success combined
                        , nextCursor = page.nextCursor
                        , loadingMore = False
                      }
                    , Cmd.none
                    )

                Err err ->
                    -- A failed later page must not erase the pages already read.
                    case model.posts of
                        Success existing ->
                            ( { model | posts = Success existing, loadingMore = False }
                            , Cmd.none
                            )

                        _ ->
                            ( { model | posts = Failure err, loadingMore = False }, Cmd.none )

        LoadMore ->
            case model.nextCursor of
                Just cursor ->
                    ( { model | loadingMore = True }
                    , Api.getBlogPosts model.token (Just cursor) PostsLoaded
                    )

                Nothing ->
                    ( model, Cmd.none )


view : Model -> Html Msg
view model =
    div [ class "page page--blog-archive" ]
        [ div [ class "blog-archive__header" ]
            [ h1 [ class "page__title" ] [ text "Blog" ]
            , if model.isAuthenticated then
                a [ href (Route.toPath BlogNew), class "btn btn--primary" ]
                    [ text "New Post" ]

              else
                text ""
            ]
        , div [ class "blog-archive__content" ]
            [ case model.posts of
                NotAsked ->
                    text ""

                Loading ->
                    p [ class "loading" ] [ text "Loading posts..." ]

                Failure _ ->
                    p [ class "error" ] [ text "Could not load posts. Please try again." ]

                Success posts ->
                    div []
                        [ if List.isEmpty posts then
                            -- ⚠️ "No posts yet" only while there is genuinely
                            -- nothing more to ask for. An empty FIRST page with a
                            -- cursor behind it means this reader cannot see the
                            -- newest window, not that nobody has written anything.
                            if model.nextCursor == Nothing then
                                p [ class "blog-archive__empty" ]
                                    [ text "No posts yet." ]

                            else
                                p [ class "blog-archive__empty" ]
                                    [ text "Nothing here you can read — there is more further back." ]

                          else
                            ul [ class "blog-archive__list" ]
                                (List.map viewPostSummary posts)
                        , viewLoadMore model
                        ]
            ]
        ]


{-| "Load more" affordance, shown while the server still has a cursor for us.

Driven by the cursor rather than by how many posts are on screen: a page may be
short of the window without being the last one.

-}
viewLoadMore : Model -> Html Msg
viewLoadMore model =
    case model.nextCursor of
        Just _ ->
            div [ class "blog-archive__load-more" ]
                [ button
                    [ class "btn btn--small btn--secondary"
                    , disabled model.loadingMore
                    , onClick LoadMore
                    ]
                    [ text
                        (if model.loadingMore then
                            "Loading…"

                         else
                            "Load more"
                        )
                    ]
                ]

        Nothing ->
            text ""


{-| How much of a post the archive shows before asking the reader to open it.

Bounded by characters, not by lines. Markdown does not hard-wrap, so a
paragraph is a single line — taking "the first two lines" took the first two
paragraphs entire, and a post that opened with a long paragraph printed the
whole thing into the list.

-}
previewLimit : Int
previewLimit =
    200


{-| A bounded, single-line excerpt of a post body, cut at a word boundary and
marked with an ellipsis when there is more to read.
-}
previewOf : String -> String
previewOf body =
    let
        flattened =
            body
                |> String.lines
                |> List.map String.trim
                |> List.filter (not << String.isEmpty)
                |> String.join " "
    in
    if String.length flattened <= previewLimit then
        flattened

    else
        let
            cut =
                String.left previewLimit flattened

            atWordBoundary =
                case List.reverse (String.indexes " " cut) of
                    lastSpace :: _ ->
                        String.left lastSpace cut

                    [] ->
                        cut
        in
        atWordBoundary ++ "…"


viewPostSummary : BlogPostSummary -> Html Msg
viewPostSummary post =
    let
        preview =
            previewOf post.body
    in
    li [ class "blog-archive__item" ]
        [ a [ href (Route.toPath (BlogPost post.id)), class "blog-archive__link" ]
            [ div [ class "blog-archive__item-header" ]
                [ h2 [ class "blog-archive__item-title" ] [ text post.title ]
                , VisibilityBadge.view (visibilityToString post.visibility)
                ]
            , p [ class "blog-archive__item-meta" ]
                [ case post.authorDisplayName of
                    -- The byline is plain text inside the post link rather than a
                    -- second link to the author: an anchor nested in an anchor is
                    -- invalid, and the post is what the reader came to open.
                    Just name ->
                        span [ class "blog-archive__item-author" ] [ text name ]

                    Nothing ->
                        text ""
                , span [ class "blog-archive__item-date" ] [ text post.insertedAt ]
                ]
            , p [ class "blog-archive__item-preview" ] [ text preview ]
            ]
        ]
