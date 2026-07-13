module BlogPostCommentTest exposing (suite)

import Expect
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Page.Blog.Post as Post exposing (Msg(..))
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.BlogPost exposing (Comment(..), Visibility(..), commentDecoder, commentReplies)
import Types.RemoteData exposing (RemoteData(..))


testComment : Comment
testComment =
    Comment
        { id = "comment-1"
        , postId = "post-1"
        , authorId = "author-1"
        , parentId = Nothing
        , body = "Great post!"
        , createdAt = "2026-03-29T12:00:00Z"
        , replies = []
        }


testModel : Post.Model
testModel =
    { postId = "post-1"
    , post = NotAsked
    , currentUserId = Nothing
    , writingAssistantConsent = False
    , actionResult = NotAsked
    , comments = NotAsked
    , commentDraft = ""
    , replyDraft = Nothing
    , commentSubmitting = False
    }


suite : Test
suite =
    describe "Page.Blog.Post comments"
        [ describe "commentDecoder"
            [ test "decodes a flat comment with no replies" <|
                \_ ->
                    let
                        json =
                            Encode.object
                                [ ( "id", Encode.string "c-1" )
                                , ( "postId", Encode.string "p-1" )
                                , ( "authorId", Encode.string "u-1" )
                                , ( "parentId", Encode.null )
                                , ( "body", Encode.string "Hello" )
                                , ( "createdAt", Encode.string "2026-03-29T12:00:00Z" )
                                ]

                        result =
                            Decode.decodeValue commentDecoder json
                    in
                    case result of
                        Ok (Comment c) ->
                            Expect.all
                                [ \r -> Expect.equal "c-1" r.id
                                , \r -> Expect.equal [] r.replies
                                , \r -> Expect.equal Nothing r.parentId
                                ]
                                c

                        Err e ->
                            Expect.fail (Decode.errorToString e)
            , test "decodes nested replies via lazy recursion" <|
                \_ ->
                    let
                        replyJson =
                            Encode.object
                                [ ( "id", Encode.string "c-2" )
                                , ( "postId", Encode.string "p-1" )
                                , ( "authorId", Encode.string "u-2" )
                                , ( "parentId", Encode.string "c-1" )
                                , ( "body", Encode.string "Reply" )
                                , ( "createdAt", Encode.string "2026-03-29T13:00:00Z" )
                                ]

                        parentJson =
                            Encode.object
                                [ ( "id", Encode.string "c-1" )
                                , ( "postId", Encode.string "p-1" )
                                , ( "authorId", Encode.string "u-1" )
                                , ( "parentId", Encode.null )
                                , ( "body", Encode.string "Parent" )
                                , ( "createdAt", Encode.string "2026-03-29T12:00:00Z" )
                                , ( "replies", Encode.list identity [ replyJson ] )
                                ]

                        result =
                            Decode.decodeValue commentDecoder parentJson
                    in
                    case result of
                        Ok comment ->
                            let
                                replies =
                                    commentReplies comment
                            in
                            Expect.equal 1 (List.length replies)

                        Err e ->
                            Expect.fail (Decode.errorToString e)
            ]
        , describe "CommentsLoaded"
            [ test "Ok sets comments to Success" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Post.update (CommentsLoaded (Ok [ testComment ])) testModel Nothing
                    in
                    Expect.equal (Success [ testComment ]) model.comments
            , test "Err sets comments to Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Post.update (CommentsLoaded (Err (Http.BadStatus 500))) testModel Nothing
                    in
                    case model.comments of
                        Failure _ ->
                            Expect.pass

                        _ ->
                            Expect.fail "Expected Failure"
            ]
        , describe "CommentDraftChanged"
            [ test "updates commentDraft" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Post.update (CommentDraftChanged "hello") testModel Nothing
                    in
                    Expect.equal "hello" model.commentDraft
            ]
        , describe "ReplyClicked"
            [ test "sets replyDraft with parentId and empty body" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Post.update (ReplyClicked "parent-id") testModel Nothing
                    in
                    Expect.equal (Just { parentId = "parent-id", body = "" }) model.replyDraft
            ]
        , describe "ReplyDraftChanged"
            [ test "updates replyDraft body when draft exists" <|
                \_ ->
                    let
                        modelWithDraft =
                            { testModel | replyDraft = Just { parentId = "parent-id", body = "" } }

                        ( model, _, _ ) =
                            Post.update (ReplyDraftChanged "my reply") modelWithDraft Nothing
                    in
                    Expect.equal (Just { parentId = "parent-id", body = "my reply" }) model.replyDraft
            , test "does nothing when no draft exists" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Post.update (ReplyDraftChanged "my reply") testModel Nothing
                    in
                    Expect.equal Nothing model.replyDraft
            ]
        , describe "CommentSubmitted"
            [ test "Ok clears draft and stops submitting" <|
                \_ ->
                    let
                        submittingModel =
                            { testModel | commentSubmitting = True, commentDraft = "hello" }

                        ( model, _, _ ) =
                            Post.update (CommentSubmitted (Ok testComment)) submittingModel Nothing
                    in
                    Expect.all
                        [ \m -> Expect.equal False m.commentSubmitting
                        , \m -> Expect.equal "" m.commentDraft
                        , \m -> Expect.equal Nothing m.replyDraft
                        ]
                        model
            , test "Err stops submitting but keeps draft" <|
                \_ ->
                    let
                        submittingModel =
                            { testModel | commentSubmitting = True, commentDraft = "hello" }

                        ( model, _, _ ) =
                            Post.update (CommentSubmitted (Err (Http.BadStatus 500))) submittingModel Nothing
                    in
                    Expect.all
                        [ \m -> Expect.equal False m.commentSubmitting
                        , \m -> Expect.equal "hello" m.commentDraft
                        ]
                        model
            ]
        , describe "SubmitComment"
            [ test "empty draft does not submit" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Post.update SubmitComment testModel (Just "token")
                    in
                    Expect.equal False model.commentSubmitting
            , test "non-empty draft with token sets submitting" <|
                \_ ->
                    let
                        draftModel =
                            { testModel | commentDraft = "hello" }

                        ( model, _, _ ) =
                            Post.update SubmitComment draftModel (Just "token")
                    in
                    Expect.equal True model.commentSubmitting
            , test "non-empty draft without token does not submit" <|
                \_ ->
                    let
                        draftModel =
                            { testModel | commentDraft = "hello" }

                        ( model, _, _ ) =
                            Post.update SubmitComment draftModel Nothing
                    in
                    Expect.equal False model.commentSubmitting
            ]
        , describe "viewCommentBody author badge"
            [ test "author badge shown when comment author is the post author" <|
                \_ ->
                    let
                        postAuthorId =
                            "post-author-id"

                        comment =
                            Comment
                                { id = "c-1"
                                , postId = "post-1"
                                , authorId = postAuthorId
                                , parentId = Nothing
                                , body = "Author comment"
                                , createdAt = "2026-03-29T12:00:00Z"
                                , replies = []
                                }

                        post =
                            { id = "post-1"
                            , userId = postAuthorId
                            , title = "Test Post"
                            , body = "Post body"
                            , visibility = Owner
                            , published = True
                            , insertedAt = "2026-03-29T12:00:00Z"
                            , associations = []
                            }

                        model =
                            { testModel
                                | post = Success post
                                , comments = Success [ comment ]
                            }
                    in
                    Post.view model
                        |> Query.fromHtml
                        |> Query.find [ Selector.class "comment__author-badge" ]
                        |> Query.has [ Selector.text "(author)" ]
            , test "no author badge when comment author is not the post author" <|
                \_ ->
                    let
                        comment =
                            Comment
                                { id = "c-2"
                                , postId = "post-1"
                                , authorId = "other-user"
                                , parentId = Nothing
                                , body = "Non-author comment"
                                , createdAt = "2026-03-29T12:00:00Z"
                                , replies = []
                                }

                        post =
                            { id = "post-1"
                            , userId = "post-author-id"
                            , title = "Test Post"
                            , body = "Post body"
                            , visibility = Owner
                            , published = True
                            , insertedAt = "2026-03-29T12:00:00Z"
                            , associations = []
                            }

                        model =
                            { testModel
                                | post = Success post
                                , comments = Success [ comment ]
                            }
                    in
                    Post.view model
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.class "comment__author-badge" ]
            ]
        ]
