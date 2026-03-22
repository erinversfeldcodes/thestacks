module Page.Blog.Archive exposing
    ( Model
    , Msg
    , init
    , update
    , view
    )

import Api
import Components.VisibilityBadge as VisibilityBadge
import Html exposing (Html, a, div, h1, h2, li, p, text, ul)
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


viewPostSummary : BlogPostSummary -> Html Msg
viewPostSummary post =
    let
        preview =
            post.body
                |> String.lines
                |> List.take 2
                |> String.join "\n"
    in
    li [ class "blog-archive__item" ]
        [ a [ href (Route.toPath (BlogPost post.id)), class "blog-archive__link" ]
            [ div [ class "blog-archive__item-header" ]
                [ h2 [ class "blog-archive__item-title" ] [ text post.title ]
                , VisibilityBadge.view (visibilityToString post.visibility)
                ]
            , p [ class "blog-archive__item-date" ] [ text post.insertedAt ]
            , p [ class "blog-archive__item-preview" ] [ text preview ]
            ]
        ]
