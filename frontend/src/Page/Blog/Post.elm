module Page.Blog.Post exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api
import Components.BlockUserModal as BlockModal
import Components.BookAssociations as BookAssociations
import Components.Syndication as Syndication
import Components.WritingAssistant as WritingAssistant
import Html exposing (Html, a, button, div, h1, h2, p, pre, span, text, textarea)
import Html.Attributes exposing (class, disabled, href, placeholder, value)
import Html.Events exposing (onClick, onInput)
import Http
import Navigation.Route as Route exposing (Route(..))
import Types.BlogPost exposing (BlogPost, Comment, commentAuthorId, commentBody, commentCreatedAt, commentId, commentReplies)
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { postId : String
    , post : RemoteData Http.Error BlogPost
    , currentUserId : Maybe String
    , writingAssistantConsent : Bool
    , actionResult : RemoteData Http.Error ()
    , comments : RemoteData Http.Error (List Comment)
    , commentDraft : String
    , replyDraft : Maybe { parentId : String, body : String }
    , commentSubmitting : Bool
    , blockModal : Maybe BlockModal.Model
    , origin : String
    , syndication : Maybe Syndication.Model
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
    | CommentDeleted (Result Http.Error ())
    | BlockModalMsg BlockModal.Msg
    | SyndicationMsg Syndication.Msg
    | EscapePressed


type OutMsg
    = NoOut
    | SessionExpired
    | EscapeUnhandled
    | RequestCopy String


init : String -> Maybe String -> Maybe String -> Bool -> String -> ( Model, Cmd Msg )
init postId maybeToken currentUserId writingAssistantConsent origin =
    ( { postId = postId
      , post = Loading
      , currentUserId = currentUserId
      , writingAssistantConsent = writingAssistantConsent
      , actionResult = NotAsked
      , comments = Loading
      , commentDraft = ""
      , replyDraft = Nothing
      , commentSubmitting = False
      , blockModal = Nothing
      , origin = origin
      , syndication = Nothing
      }
    , Cmd.batch
        [ Api.getBlogPost postId maybeToken PostLoaded
        , Api.getPostComments postId maybeToken CommentsLoaded
        ]
    )


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        PostLoaded result ->
            case result of
                Ok post ->
                    ( { model
                        | post = Success post
                        , blockModal = blockModalFor model.currentUserId post
                        , syndication =
                            if model.currentUserId == Just post.userId then
                                Just (Syndication.init post.id model.origin post.syndicated)

                            else
                                Nothing
                      }
                    , Cmd.none
                    , NoOut
                    )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | post = Failure err }, Cmd.none, NoOut )

        ConfirmAssociation associationId ->
            case maybeToken of
                Just token ->
                    ( { model | actionResult = Loading }
                    , Api.confirmAssociation model.postId associationId token AssociationActionCompleted
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        DismissAssociation associationId ->
            case maybeToken of
                Just token ->
                    ( { model | actionResult = Loading }
                    , Api.dismissAssociation model.postId associationId token AssociationActionCompleted
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        AssociationActionCompleted result ->
            case result of
                Ok _ ->
                    ( { model | actionResult = Success () }
                    , Api.getBlogPost model.postId maybeToken PostLoaded
                    , NoOut
                    )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | actionResult = Failure err }, Cmd.none, NoOut )

        CommentsLoaded result ->
            case result of
                Ok comments ->
                    ( { model | comments = Success comments }, Cmd.none, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | comments = Failure err }, Cmd.none, NoOut )

        CommentDraftChanged draft ->
            ( { model | commentDraft = draft }, Cmd.none, NoOut )

        ReplyClicked parentId ->
            ( { model | replyDraft = Just { parentId = parentId, body = "" } }, Cmd.none, NoOut )

        ReplyDraftChanged body ->
            case model.replyDraft of
                Just draft ->
                    ( { model | replyDraft = Just { draft | body = body } }, Cmd.none, NoOut )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        SubmitComment ->
            if String.trim model.commentDraft == "" then
                ( model, Cmd.none, NoOut )

            else
                case maybeToken of
                    Just token ->
                        ( { model | commentSubmitting = True }
                        , Api.createComment model.postId model.commentDraft Nothing token CommentSubmitted
                        , NoOut
                        )

                    Nothing ->
                        ( model, Cmd.none, NoOut )

        SubmitReply parentId ->
            case model.replyDraft of
                Just draft ->
                    if String.trim draft.body == "" then
                        ( model, Cmd.none, NoOut )

                    else
                        case maybeToken of
                            Just token ->
                                ( { model | commentSubmitting = True }
                                , Api.createComment model.postId draft.body (Just parentId) token CommentSubmitted
                                , NoOut
                                )

                            Nothing ->
                                ( model, Cmd.none, NoOut )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        CommentSubmitted result ->
            case result of
                Ok _ ->
                    ( { model | commentSubmitting = False, commentDraft = "", replyDraft = Nothing }
                    , Api.getPostComments model.postId maybeToken CommentsLoaded
                    , NoOut
                    )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | commentSubmitting = False }, Cmd.none, NoOut )

        DeleteComment commentId ->
            case maybeToken of
                Just token ->
                    ( model, Api.deleteComment commentId token CommentDeleted, NoOut )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        CommentDeleted result ->
            case result of
                Ok _ ->
                    ( model, Api.getPostComments model.postId maybeToken CommentsLoaded, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( model, Cmd.none, NoOut )

        BlockModalMsg subMsg ->
            case model.blockModal of
                Just blockModal ->
                    let
                        ( newBlockModal, subCmd, outMsg ) =
                            BlockModal.update subMsg blockModal maybeToken
                    in
                    case outMsg of
                        BlockModal.NoOut ->
                            ( { model | blockModal = Just newBlockModal }
                            , Cmd.map BlockModalMsg subCmd
                            , NoOut
                            )

                        BlockModal.UserBlocked ->
                            ( { model | blockModal = Just newBlockModal }
                            , Cmd.batch
                                [ Cmd.map BlockModalMsg subCmd
                                , Api.getBlogPost model.postId maybeToken PostLoaded
                                ]
                            , NoOut
                            )

                        BlockModal.SessionExpired ->
                            ( model, Cmd.none, SessionExpired )

                        BlockModal.Dismissed ->
                            ( { model | blockModal = Just newBlockModal }
                            , Cmd.map BlockModalMsg subCmd
                            , NoOut
                            )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        SyndicationMsg subMsg ->
            case model.syndication of
                Just syndicationModel ->
                    let
                        ( newSyndication, subCmd, outMsg ) =
                            Syndication.update subMsg syndicationModel maybeToken

                        baseModel =
                            { model | syndication = Just newSyndication }
                    in
                    case outMsg of
                        Syndication.NoOut ->
                            ( baseModel, Cmd.map SyndicationMsg subCmd, NoOut )

                        Syndication.RequestCopy payload ->
                            ( baseModel, Cmd.map SyndicationMsg subCmd, RequestCopy payload )

                        Syndication.SyndicatedChanged syndicated ->
                            ( { baseModel
                                | post =
                                    case baseModel.post of
                                        Success post ->
                                            Success { post | syndicated = syndicated }

                                        other ->
                                            other
                              }
                            , Cmd.map SyndicationMsg subCmd
                            , NoOut
                            )

                        Syndication.AuthLost ->
                            ( baseModel, Cmd.none, SessionExpired )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        EscapePressed ->
            case model.blockModal of
                Just blockModal ->
                    let
                        ( newBlockModal, subCmd, outMsg ) =
                            BlockModal.update BlockModal.EscapePressed blockModal maybeToken
                    in
                    case outMsg of
                        BlockModal.Dismissed ->
                            ( { model | blockModal = Just newBlockModal }
                            , Cmd.map BlockModalMsg subCmd
                            , NoOut
                            )

                        _ ->
                            ( model, Cmd.none, EscapeUnhandled )

                Nothing ->
                    ( model, Cmd.none, EscapeUnhandled )


{-| A block affordance is only offered to a signed-in reader who is not the
post's author (you can't block yourself). The confirmation names the author
using the post payload's `authorDisplayName`, falling back to a generic label
when it is absent (older payloads or an unloaded author association).
-}
blockModalFor : Maybe String -> BlogPost -> Maybe BlockModal.Model
blockModalFor currentUserId post =
    case currentUserId of
        Just uid ->
            if uid == post.userId then
                Nothing

            else
                Just
                    (BlockModal.init
                        { userId = post.userId
                        , displayName = authorLabel post
                        }
                    )

        Nothing ->
            Nothing


{-| The author's display name for the block confirmation, with a safe generic
fallback when the payload carries no name.
-}
authorLabel : BlogPost -> String
authorLabel post =
    if String.trim post.authorDisplayName == "" then
        "the author"

    else
        post.authorDisplayName


view : Model -> Html Msg
view model =
    div [ class "page page--blog-post" ]
        [ case model.post of
            NotAsked ->
                text ""

            Loading ->
                p [ class "loading" ] [ text "Loading post..." ]

            Failure err ->
                if Api.isNotFound err then
                    div [ class "blog-post__unavailable" ]
                        [ p [ class "blog-post__unavailable-text" ]
                            [ text "This post is no longer available." ]
                        ]

                else
                    p [ class "error" ] [ text "Could not load post. Please try again." ]

            Success post ->
                let
                    isOwner =
                        model.currentUserId == Just post.userId
                in
                div []
                    [ viewPost post isOwner
                    , case model.syndication of
                        Just syndicationModel ->
                            Html.map SyndicationMsg
                                (Syndication.view
                                    syndicationModel
                                    post.authorHandle
                                    (post.visibility == Types.BlogPost.Public && post.published)
                                )

                        Nothing ->
                            text ""
                    , case model.blockModal of
                        Just blockModal ->
                            Html.map BlockModalMsg (BlockModal.view blockModal)

                        Nothing ->
                            text ""
                    , if isOwner then
                        WritingAssistant.view { hasConsent = model.writingAssistantConsent }

                      else
                        text ""
                    , viewComments model
                    ]
        ]


viewPost : BlogPost -> Bool -> Html Msg
viewPost post isOwner =
    div [ class "blog-post" ]
        [ div [ class "blog-post__header" ]
            [ h1 [ class "blog-post__title" ] [ text post.title ]
            , viewAuthorByline post
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


{-| Render the author's name as a link to their public profile (US-10.5.4).

When the author handle is present the display name links to `/u/:handle`;
following the link to a ghost/blocked author still resolves to the profile
gate's "Reader not found" (defence in depth). When no handle is present (older
payloads or an unloaded author association) the name renders as plain text, and
when neither name nor handle is present the byline is omitted entirely.

-}
viewAuthorByline : BlogPost -> Html Msg
viewAuthorByline post =
    let
        name =
            if String.trim post.authorDisplayName == "" then
                "the author"

            else
                post.authorDisplayName
    in
    if String.trim post.authorHandle /= "" then
        p [ class "blog-post__byline" ]
            [ text "by "
            , a
                [ href (Route.toPath (Route.Profile post.authorHandle))
                , class "blog-post__author-link"
                ]
                [ text name ]
            ]

    else if String.trim post.authorDisplayName /= "" then
        p [ class "blog-post__byline" ]
            [ text "by ", span [ class "blog-post__author" ] [ text name ] ]

    else
        text ""


viewComments : Model -> Html Msg
viewComments model =
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
