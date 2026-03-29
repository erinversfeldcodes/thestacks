module Page.Blog.Post exposing
    ( Model
    , Msg(..)
    , init
    , update
    , view
    )

import Api
import Components.BookAssociations as BookAssociations
import Html exposing (Html, a, button, div, h1, h2, p, pre, span, text, textarea)
import Html.Attributes exposing (class, disabled, href, placeholder, value)
import Html.Events exposing (onClick, onInput)
import Http
import Navigation.Route as Route exposing (Route(..))
import Types.BlogPost exposing (BlogPost, Comment, commentAuthorId, commentBody, commentCreatedAt, commentId, commentParentId, commentReplies)
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { postId : String
    , post : RemoteData Http.Error BlogPost
    , currentUserId : Maybe String
    , actionResult : RemoteData Http.Error ()
    , comments : RemoteData Http.Error (List Comment)
    , commentDraft : String
    , replyDraft : Maybe { parentId : String, body : String }
    , commentSubmitting : Bool
    }


type Msg
    = PostLoaded (Result Http.Error BlogPost)
    | ConfirmAssociation String
    | DismissAssociation String
    | AssociationActionCompleted (Result Http.Error ())
    | CommentsLoaded (Result Http.Error (List Comment))
    | CommentDraftChanged String
    | ReplyClicked String
    | ReplyDraftChanged String
    | SubmitComment
    | SubmitReply String
    | CommentSubmitted (Result Http.Error Comment)
    | DeleteComment String
    | CommentDeleted String (Result Http.Error ())


init : String -> Maybe String -> Maybe String -> ( Model, Cmd Msg )
init postId maybeToken currentUserId =
    ( { postId = postId
      , post = Loading
      , currentUserId = currentUserId
      , actionResult = NotAsked
      , comments = Loading
      , commentDraft = ""
      , replyDraft = Nothing
      , commentSubmitting = False
      }
    , Cmd.batch
        [ Api.getBlogPost postId maybeToken PostLoaded
        , Api.getPostComments postId maybeToken CommentsLoaded
        ]
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

        CommentsLoaded result ->
            case result of
                Ok comments ->
                    ( { model | comments = Success comments }, Cmd.none )

                Err err ->
                    ( { model | comments = Failure err }, Cmd.none )

        CommentDraftChanged draft ->
            ( { model | commentDraft = draft }, Cmd.none )

        ReplyClicked parentId ->
            ( { model | replyDraft = Just { parentId = parentId, body = "" } }, Cmd.none )

        ReplyDraftChanged body ->
            case model.replyDraft of
                Just draft ->
                    ( { model | replyDraft = Just { draft | body = body } }, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        SubmitComment ->
            if String.trim model.commentDraft == "" then
                ( model, Cmd.none )

            else
                case maybeToken of
                    Just token ->
                        ( { model | commentSubmitting = True }
                        , Api.createComment model.postId model.commentDraft Nothing token CommentSubmitted
                        )

                    Nothing ->
                        ( model, Cmd.none )

        SubmitReply parentId ->
            case model.replyDraft of
                Just draft ->
                    if String.trim draft.body == "" then
                        ( model, Cmd.none )

                    else
                        case maybeToken of
                            Just token ->
                                ( { model | commentSubmitting = True }
                                , Api.createComment model.postId draft.body (Just parentId) token CommentSubmitted
                                )

                            Nothing ->
                                ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        CommentSubmitted result ->
            case result of
                Ok _ ->
                    ( { model | commentSubmitting = False, commentDraft = "", replyDraft = Nothing }
                    , Api.getPostComments model.postId maybeToken CommentsLoaded
                    )

                Err _ ->
                    ( { model | commentSubmitting = False }, Cmd.none )

        DeleteComment commentId ->
            case maybeToken of
                Just token ->
                    ( model, Api.deleteComment commentId token (CommentDeleted commentId) )

                Nothing ->
                    ( model, Cmd.none )

        CommentDeleted _ result ->
            case result of
                Ok _ ->
                    ( model, Api.getPostComments model.postId maybeToken CommentsLoaded )

                Err _ ->
                    ( model, Cmd.none )


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
                div []
                    [ viewPost post isOwner
                    , viewComments model post
                    ]
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


viewComments : Model -> BlogPost -> Html Msg
viewComments model _ =
    div [ class "blog-post__comments" ]
        [ h2 [ class "comments__heading" ] [ text "Comments" ]
        , case model.comments of
            NotAsked ->
                text ""

            Loading ->
                p [ class "comments__loading" ] [ text "Loading comments..." ]

            Failure _ ->
                p [ class "comments__error" ] [ text "Could not load comments." ]

            Success comments ->
                div []
                    [ div [ class "comments__list" ]
                        (List.map (viewTopLevelComment model) comments)
                    , viewCommentForm model
                    ]
        ]


viewTopLevelComment : Model -> Comment -> Html Msg
viewTopLevelComment model comment =
    div [ class "comment" ]
        [ viewCommentBody model comment True
        , div [ class "comment__replies" ]
            (List.map (\reply -> viewCommentBody model reply False) (commentReplies comment))
        , case model.replyDraft of
            Just draft ->
                if draft.parentId == commentId comment then
                    viewReplyForm (commentId comment) draft.body

                else
                    text ""

            Nothing ->
                text ""
        ]


viewCommentBody : Model -> Comment -> Bool -> Html Msg
viewCommentBody model comment showReplyButton =
    let
        canDelete =
            case model.post of
                Success post ->
                    model.currentUserId == Just (commentAuthorId comment) || model.currentUserId == Just post.userId

                _ ->
                    model.currentUserId == Just (commentAuthorId comment)

        isPostAuthor =
            case model.post of
                Success post ->
                    commentAuthorId comment == post.userId

                _ ->
                    False
    in
    div [ class "comment__body" ]
        [ div [ class "comment__meta" ]
            [ if isPostAuthor then
                span [ class "comment__author-badge" ] [ text "(author)" ]

              else
                text ""
            , span [ class "comment__date" ] [ text (commentCreatedAt comment) ]
            ]
        , p [ class "comment__text" ] [ text (commentBody comment) ]
        , div [ class "comment__actions" ]
            [ if canDelete then
                button
                    [ class "btn btn--link comment__delete"
                    , onClick (DeleteComment (commentId comment))
                    ]
                    [ text "Delete" ]

              else
                text ""
            , if showReplyButton then
                button
                    [ class "btn btn--link comment__reply"
                    , onClick (ReplyClicked (commentId comment))
                    ]
                    [ text "Reply" ]

              else
                text ""
            ]
        ]


viewCommentForm : Model -> Html Msg
viewCommentForm model =
    if model.currentUserId /= Nothing then
        div [ class "comment-form" ]
            [ textarea
                [ class "comment-form__input"
                , placeholder "Leave a comment..."
                , onInput CommentDraftChanged
                , value model.commentDraft
                ]
                []
            , button
                [ class "btn btn--primary comment-form__submit"
                , onClick SubmitComment
                , disabled model.commentSubmitting
                ]
                [ text
                    (if model.commentSubmitting then
                        "Posting..."

                     else
                        "Post Comment"
                    )
                ]
            ]

    else
        text ""


viewReplyForm : String -> String -> Html Msg
viewReplyForm parentId body =
    div [ class "reply-form" ]
        [ textarea
            [ class "reply-form__input"
            , placeholder "Write a reply..."
            , onInput ReplyDraftChanged
            , value body
            ]
            []
        , button
            [ class "btn btn--primary reply-form__submit"
            , onClick (SubmitReply parentId)
            ]
            [ text "Post Reply" ]
        ]
