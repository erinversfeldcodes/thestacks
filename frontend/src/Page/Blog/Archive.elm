module Page.Blog.Archive exposing
    ( Model
    , Msg
    , init
    , previewOf
    , update
    , view
    )

import Api
import Components.VisibilityBadge as VisibilityBadge
import Html exposing (Html, a, div, h1, h2, li, p, span, text, ul)
import Html.Attributes exposing (class, href)
import Http
import Navigation.Route as Route exposing (Route(..))
import Types.BlogPost exposing (BlogPostSummary, visibilityToString)
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { posts : RemoteData Http.Error (List BlogPostSummary)
    , isAuthenticated : Bool
    }


type Msg
    = PostsLoaded (Result Http.Error (List BlogPostSummary))


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    ( { posts = Loading
      , isAuthenticated = maybeToken /= Nothing
      }
    , Api.getBlogPosts maybeToken PostsLoaded
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        PostsLoaded result ->
            case result of
                Ok posts ->
                    ( { model | posts = Success posts }, Cmd.none )

                Err err ->
                    ( { model | posts = Failure err }, Cmd.none )


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
                    if List.isEmpty posts then
                        p [ class "blog-archive__empty" ]
                            [ text "No posts yet." ]

                    else
                        ul [ class "blog-archive__list" ]
                            (List.map viewPostSummary posts)
            ]
        ]


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
