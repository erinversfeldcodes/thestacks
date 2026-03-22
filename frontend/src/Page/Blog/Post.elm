module Page.Blog.Post exposing
    ( Model
    , Msg(..)
    , init
    , update
    , view
    )

import Api
import Components.BookAssociations as BookAssociations
import Html exposing (Html, a, div, h1, p, pre, text)
import Html.Attributes exposing (class, href)
import Http
import Navigation.Route as Route exposing (Route(..))
import Types.BlogPost exposing (BlogPost, blogPostDecoder)
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { postId : String
    , post : RemoteData Http.Error BlogPost
    , currentUserId : Maybe String
    , actionResult : RemoteData Http.Error ()
    }


type Msg
    = PostLoaded (Result Http.Error BlogPost)
    | ConfirmAssociation String
    | DismissAssociation String
    | AssociationActionCompleted (Result Http.Error ())


init : String -> Maybe String -> Maybe String -> ( Model, Cmd Msg )
init postId maybeToken currentUserId =
    ( { postId = postId
      , post = Loading
      , currentUserId = currentUserId
      , actionResult = NotAsked
      }
    , Api.getBlogPost postId maybeToken PostLoaded
    )


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg )
update msg model maybeToken =
    case msg of
        PostLoaded result ->
            case result of
                Ok post ->
                    ( { model | post = Success post }, Cmd.none )

                Err err ->
                    ( { model | post = Failure err }, Cmd.none )

        ConfirmAssociation associationId ->
            case maybeToken of
                Just token ->
                    ( { model | actionResult = Loading }
                    , Api.confirmAssociation model.postId associationId token AssociationActionCompleted
                    )

                Nothing ->
                    ( model, Cmd.none )

        DismissAssociation associationId ->
            case maybeToken of
                Just token ->
                    ( { model | actionResult = Loading }
                    , Api.dismissAssociation model.postId associationId token AssociationActionCompleted
                    )

                Nothing ->
                    ( model, Cmd.none )

        AssociationActionCompleted result ->
            case result of
                Ok _ ->
                    ( { model | actionResult = Success () }
                    , Api.getBlogPost model.postId maybeToken PostLoaded
                    )

                Err err ->
                    ( { model | actionResult = Failure err }, Cmd.none )


view : Model -> Html Msg
view model =
    div [ class "page page--blog-post" ]
        [ case model.post of
            NotAsked ->
                text ""

            Loading ->
                p [ class "loading" ] [ text "Loading post..." ]

            Failure _ ->
                p [ class "error" ] [ text "Could not load post. Please try again." ]

            Success post ->
                let
                    isOwner =
                        model.currentUserId == Just post.userId
                in
                viewPost post isOwner
        ]


viewPost : BlogPost -> Bool -> Html Msg
viewPost post isOwner =
    div [ class "blog-post" ]
        [ div [ class "blog-post__header" ]
            [ h1 [ class "blog-post__title" ] [ text post.title ]
            , p [ class "blog-post__date" ] [ text post.insertedAt ]
            , if isOwner then
                a
                    [ href (Route.toPath (BlogEdit post.id))
                    , class "btn btn--secondary"
                    ]
                    [ text "Edit" ]

              else
                text ""
            ]
        , div [ class "blog-post__body" ]
            [ pre [ class "blog-post__content" ] [ text post.body ] ]
        , BookAssociations.view
            { associations = post.associations
            , isOwner = isOwner
            , onConfirm = ConfirmAssociation
            , onDismiss = DismissAssociation
            }
        ]
