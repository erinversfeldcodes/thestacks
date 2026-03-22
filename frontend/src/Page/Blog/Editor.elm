module Page.Blog.Editor exposing
    ( Mode(..)
    , Model
    , Msg(..)
    , init
    , update
    , view
    )

import Api
import Html exposing (Html, button, div, h1, label, option, p, select, text, textarea)
import Html.Attributes exposing (class, disabled, placeholder, rows, selected, value)
import Html.Events exposing (onClick, onInput)
import Http
import Types.BlogPost exposing (BlogPost, Visibility(..), blogPostDecoder, visibilityToString)
import Types.RemoteData exposing (RemoteData(..))


type Mode
    = New
    | Edit String


type alias Model =
    { mode : Mode
    , title : String
    , body : String
    , visibility : Visibility
    , saving : RemoteData Http.Error ()
    , publishing : RemoteData Http.Error ()
    , loading : RemoteData Http.Error ()
    }


type Msg
    = SetTitle String
    | SetBody String
    | SetVisibility String
    | SaveDraft
    | Publish
    | SaveCompleted (Result Http.Error String)
    | PublishCompleted (Result Http.Error ())
    | PostLoaded (Result Http.Error BlogPost)


init : Mode -> Maybe String -> ( Model, Cmd Msg )
init mode maybeToken =
    let
        baseModel =
            { mode = mode
            , title = ""
            , body = ""
            , visibility = Owner
            , saving = NotAsked
            , publishing = NotAsked
            , loading = NotAsked
            }

        cmd =
            case mode of
                Edit postId ->
                    Api.getBlogPost postId maybeToken PostLoaded

                New ->
                    Cmd.none
    in
    ( case mode of
        Edit _ ->
            { baseModel | loading = Loading }

        New ->
            baseModel
    , cmd
    )


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg )
update msg model maybeToken =
    case msg of
        SetTitle val ->
            ( { model | title = val, saving = NotAsked }, Cmd.none )

        SetBody val ->
            ( { model | body = val, saving = NotAsked }, Cmd.none )

        SetVisibility val ->
            let
                vis =
                    case val of
                        "group" ->
                            Group

                        "platform" ->
                            Platform

                        _ ->
                            Owner
            in
            ( { model | visibility = vis, saving = NotAsked }, Cmd.none )

        SaveDraft ->
            case maybeToken of
                Just token ->
                    let
                        postData =
                            { title = model.title
                            , body = model.body
                            , visibility = visibilityToString model.visibility
                            }

                        cmd =
                            case model.mode of
                                New ->
                                    Api.createBlogPost postData token SaveCompleted

                                Edit postId ->
                                    Api.updateBlogPost postId postData token SaveCompleted
                    in
                    ( { model | saving = Loading }, cmd )

                Nothing ->
                    ( model, Cmd.none )

        Publish ->
            case maybeToken of
                Just token ->
                    let
                        postData =
                            { title = model.title
                            , body = model.body
                            , visibility = visibilityToString model.visibility
                            }
                    in
                    case model.mode of
                        Edit postId ->
                            -- Save first, then publish on SaveCompleted
                            ( { model | publishing = Loading, saving = Loading }
                            , Api.updateBlogPost postId postData token SaveCompleted
                            )

                        New ->
                            -- Create first, then publish on SaveCompleted
                            ( { model | publishing = Loading, saving = Loading }
                            , Api.createBlogPost postData token SaveCompleted
                            )

                Nothing ->
                    ( model, Cmd.none )

        SaveCompleted result ->
            case result of
                Ok newId ->
                    let
                        newMode =
                            case model.mode of
                                New ->
                                    Edit newId

                                _ ->
                                    model.mode

                        postId =
                            case newMode of
                                Edit id ->
                                    id

                                New ->
                                    newId

                        publishCmd =
                            if model.publishing == Loading then
                                case maybeToken of
                                    Just token ->
                                        Api.publishBlogPost postId token PublishCompleted

                                    Nothing ->
                                        Cmd.none

                            else
                                Cmd.none
                    in
                    ( { model | saving = Success (), mode = newMode }
                    , publishCmd
                    )

                Err err ->
                    ( { model | saving = Failure err, publishing = NotAsked }, Cmd.none )

        PublishCompleted result ->
            case result of
                Ok _ ->
                    ( { model | publishing = Success () }, Cmd.none )

                Err err ->
                    ( { model | publishing = Failure err }, Cmd.none )

        PostLoaded result ->
            case result of
                Ok post ->
                    ( { model
                        | title = post.title
                        , body = post.body
                        , visibility = post.visibility
                        , loading = Success ()
                      }
                    , Cmd.none
                    )

                Err err ->
                    ( { model | loading = Failure err }, Cmd.none )


view : Model -> Html Msg
view model =
    let
        heading =
            case model.mode of
                New ->
                    "New Post"

                Edit _ ->
                    "Edit Post"
    in
    div [ class "page page--blog-editor" ]
        [ h1 [ class "page__title" ] [ text heading ]
        , case model.loading of
            Failure _ ->
                p [ class "error" ] [ text "Could not load post. Please try again." ]

            Loading ->
                p [ class "loading" ] [ text "Loading..." ]

            _ ->
                viewForm model
        ]


viewForm : Model -> Html Msg
viewForm model =
    div [ class "blog-editor__form" ]
        [ div [ class "form-field" ]
            [ label [ class "form-field__label" ] [ text "Title" ]
            , Html.input
                [ Html.Attributes.type_ "text"
                , class "form-field__input"
                , value model.title
                , onInput SetTitle
                , placeholder "Post title"
                ]
                []
            ]
        , div [ class "form-field" ]
            [ label [ class "form-field__label" ] [ text "Body" ]
            , textarea
                [ class "form-field__textarea"
                , value model.body
                , onInput SetBody
                , placeholder "Write your post here..."
                , rows 20
                ]
                []
            ]
        , div [ class "form-field" ]
            [ label [ class "form-field__label" ] [ text "Visibility" ]
            , select
                [ class "form-field__select"
                , onInput SetVisibility
                ]
                [ option [ value "owner", selected (model.visibility == Owner) ] [ text "Only me" ]
                , option [ value "group", selected (model.visibility == Group) ] [ text "Group" ]
                , option [ value "platform", selected (model.visibility == Platform) ] [ text "Platform" ]
                ]
            ]
        , div [ class "blog-editor__actions" ]
            [ viewSaveButton model.saving
            , viewPublishButton model
            ]
        , viewFeedback model
        ]


viewSaveButton : RemoteData Http.Error () -> Html Msg
viewSaveButton saving =
    case saving of
        Loading ->
            button [ class "btn btn--secondary btn--disabled", disabled True ]
                [ text "Saving..." ]

        Success _ ->
            button [ class "btn btn--secondary" ]
                [ text "Draft saved!" ]

        _ ->
            button [ class "btn btn--secondary", onClick SaveDraft ]
                [ text "Save Draft" ]


viewPublishButton : Model -> Html Msg
viewPublishButton model =
    case model.publishing of
        Loading ->
            button [ class "btn btn--primary btn--disabled", disabled True ]
                [ text "Publishing..." ]

        Success _ ->
            button [ class "btn btn--primary" ]
                [ text "Published!" ]

        _ ->
            button [ class "btn btn--primary", onClick Publish ]
                [ text "Publish" ]


viewFeedback : Model -> Html Msg
viewFeedback model =
    div []
        [ case model.saving of
            Failure _ ->
                p [ class "error" ] [ text "Could not save post. Please try again." ]

            _ ->
                text ""
        , case model.publishing of
            Failure _ ->
                p [ class "error" ] [ text "Could not publish post. Please try again." ]

            _ ->
                text ""
        ]
