module Components.BlockUserModal exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , Target
    , init
    , update
    , view
    )

{-| A reusable "Block a reader" affordance: an overflow (⋯) trigger that opens
a small menu, whose "Block [name]" action opens a confirmation modal. The
actual block is fired from the modal and the outcome is reported back to the
host via `OutMsg` so it can refresh the surface (blocked content disappears
server-side once `Visibility.resolve_visibility/2` sees the block).

Model-Update-View, `RemoteData` for the request, no ports.

-}

import Api exposing (BlockError(..))
import Browser.Dom
import Html exposing (Html, button, div, p, text)
import Html.Attributes exposing (attribute, class, disabled, id, style)
import Html.Events exposing (onClick)
import Task
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


{-| The reader this affordance blocks. `displayName` is a label only.
-}
type alias Target =
    { userId : String
    , displayName : String
    }


type alias Model =
    { target : Target
    , menuOpen : Bool
    , confirming : Bool
    , status : RemoteData BlockError ()
    }


init : Target -> Model
init target =
    { target = target
    , menuOpen = False
    , confirming = False
    , status = NotAsked
    }


type Msg
    = MenuToggled
    | MenuClosed
    | EscapePressed
    | BlockRequested
    | BlockDismissed
    | BlockConfirmed
    | BlockCompleted (Result BlockError ())
    | FocusResult


type OutMsg
    = NoOut
    | UserBlocked
    | SessionExpired
    | Dismissed


{-| The DOM id of the ⋯ trigger for this target, so focus can return to it when
its menu / confirm modal closes. Unique per target, since a feed can render many
block affordances at once (Groups feed).
-}
triggerId : Target -> String
triggerId target =
    "block-user-trigger-" ++ target.userId


{-| True while a block request is in flight — the single-flight guard so a
second confirm click cannot fire a duplicate request.
-}
isBlocking : RemoteData BlockError () -> Bool
isBlocking status =
    case status of
        Loading ->
            True

        _ ->
            False


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        MenuToggled ->
            ( { model | menuOpen = not model.menuOpen }, Cmd.none, NoOut )

        MenuClosed ->
            ( { model | menuOpen = False }, focusTrigger model, NoOut )

        EscapePressed ->
            if model.confirming then
                if isBlocking model.status then
                    ( model, Cmd.none, Dismissed )

                else
                    ( { model | confirming = False, status = NotAsked }, focusTrigger model, Dismissed )

            else if model.menuOpen then
                ( { model | menuOpen = False }, focusTrigger model, Dismissed )

            else
                ( model, Cmd.none, NoOut )

        FocusResult ->
            ( model, Cmd.none, NoOut )

        BlockRequested ->
            ( { model | menuOpen = False, confirming = True, status = NotAsked }
            , Cmd.none
            , NoOut
            )

        BlockDismissed ->
            if isBlocking model.status then
                ( model, Cmd.none, NoOut )

            else
                ( { model | confirming = False, status = NotAsked }, Cmd.none, NoOut )

        BlockConfirmed ->
            if isBlocking model.status then
                ( model, Cmd.none, NoOut )

            else
                case maybeToken of
                    Just token ->
                        ( { model | status = Loading }
                        , Api.blockUser model.target.userId token BlockCompleted
                        , NoOut
                        )

                    Nothing ->
                        ( model, Cmd.none, NoOut )

        BlockCompleted (Ok ()) ->
            ( { model | status = Success (), confirming = False, menuOpen = False }
            , Cmd.none
            , UserBlocked
            )

        BlockCompleted (Err err) ->
            case err of
                BlockRequestFailed httpErr ->
                    if Api.isUnauthorized httpErr then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | status = Failure err }, Cmd.none, NoOut )

                _ ->
                    ( { model | status = Failure err }, Cmd.none, NoOut )


{-| Return DOM focus to the ⋯ trigger, discarding the (ignorable) result.
-}
focusTrigger : Model -> Cmd Msg
focusTrigger model =
    Task.attempt (\_ -> FocusResult) (Browser.Dom.focus (triggerId model.target))


view : Model -> Html Msg
view model =
    div [ class "block-user" ]
        [ button
            [ class "block-user__trigger"
            , testId "block-user-trigger"
            , id (triggerId model.target)
            , attribute "aria-label" "Reader actions"
            , attribute "aria-haspopup" "menu"
            , attribute "aria-expanded"
                (if model.menuOpen then
                    "true"

                 else
                    "false"
                )
            , onClick MenuToggled
            ]
            [ text "⋯" ]
        , if model.menuOpen then
            div []
                [ -- Transparent full-screen layer that turns an outside click
                  div
                    [ class "app-nav__backdrop"
                    , style "position" "fixed"
                    , style "top" "0"
                    , style "left" "0"
                    , style "width" "100vw"
                    , style "height" "100vh"
                    , style "z-index" "999"
                    , onClick MenuClosed
                    ]
                    []
                , div
                    [ class "block-user__menu"
                    , -- `position` is required for `z-index` to apply: without it the
                      style "position" "relative"
                    , style "z-index" "1000"
                    ]
                    [ button
                        [ class "block-user__block-action"
                        , onClick BlockRequested
                        ]
                        [ text ("Block " ++ model.target.displayName) ]
                    ]
                ]

          else
            text ""
        , if model.confirming then
            viewConfirmModal model

          else
            text ""
        ]


viewConfirmModal : Model -> Html Msg
viewConfirmModal model =
    let
        loading =
            isBlocking model.status
    in
    div [ class "block-user__modal modal-overlay", testId "block-user-modal" ]
        [ div [ class "modal" ]
            [ p [ class "modal__title" ]
                [ text ("Block " ++ model.target.displayName ++ "?") ]
            , p [ class "modal__desc" ]
                [ text "You won't see their content, and they won't see yours. You can undo this anytime from Privacy settings." ]
            , viewFeedback model.status
            , div [ class "modal__actions" ]
                [ button
                    [ class "btn btn--danger block-user__confirm"
                    , disabled loading
                    , onClick BlockConfirmed
                    ]
                    [ text
                        (if loading then
                            "Blocking…"

                         else
                            "Block"
                        )
                    ]
                , button
                    [ class "btn btn--secondary block-user__cancel"
                    , disabled loading
                    , onClick BlockDismissed
                    ]
                    [ text "Cancel" ]
                ]
            ]
        ]


viewFeedback : RemoteData BlockError () -> Html Msg
viewFeedback status =
    case status of
        Failure AlreadyBlocked ->
            p [ class "error" ] [ text "You've already blocked this reader." ]

        Failure NotFound ->
            p [ class "error" ] [ text "That reader no longer exists." ]

        Failure CannotBlockSelf ->
            p [ class "error" ] [ text "You can't block yourself." ]

        Failure (BlockRequestFailed _) ->
            p [ class "error" ] [ text "Something went wrong. Please try again." ]

        _ ->
            text ""
