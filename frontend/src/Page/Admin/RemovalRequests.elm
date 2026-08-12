module Page.Admin.RemovalRequests exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

{-| The removal-request review queue. Domain-verified requests
act immediately; anything else parks with the LISTING STILL LIVE until a
human rules. This page is that human's only view — before it, the
endpoints were live and tested and the queue was invisible, so parked
requests aged unanswered. Uses the admin session token
(`Main.adminTokenFor`), never the ordinary one.
-}

import Api exposing (RemovalRequest)
import Html exposing (Html, a, button, div, h1, li, p, span, text, ul)
import Html.Attributes exposing (class, disabled, href, rel, target)
import Html.Events exposing (onClick)
import Http
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


type alias Model =
    { requests : RemoteData Http.Error (List RemovalRequest)
    , deciding : Maybe String
    , confirming : Maybe String
    , error : Maybe String
    }


type Msg
    = RequestsReceived (Result Http.Error (List RemovalRequest))
    | RemoveClicked String
    | RemoveConfirmed String
    | RemoveCancelled
    | KeepClicked String
    | DecisionCompleted String (Result Http.Error ())


type OutMsg
    = NoOut
    | SessionExpired


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    ( { requests = Loading, deciding = Nothing, confirming = Nothing, error = Nothing }
    , fetch maybeToken
    )


fetch : Maybe String -> Cmd Msg
fetch maybeToken =
    case maybeToken of
        Just token ->
            Api.getRemovalRequests token RequestsReceived

        Nothing ->
            Cmd.none


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        RequestsReceived (Ok requests) ->
            ( { model | requests = Success requests }, Cmd.none, NoOut )

        RequestsReceived (Err err) ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
                ( { model | requests = Failure err }, Cmd.none, NoOut )

        RemoveClicked id ->
            ( { model | confirming = Just id, error = Nothing }, Cmd.none, NoOut )

        RemoveCancelled ->
            ( { model | confirming = Nothing }, Cmd.none, NoOut )

        RemoveConfirmed id ->
            decide model maybeToken id Api.honourRemovalRequest

        KeepClicked id ->
            decide model maybeToken id Api.declineRemovalRequest

        DecisionCompleted id (Ok ()) ->
            ( { model
                | requests = removeById id model.requests
                , deciding = Nothing
                , confirming = Nothing
                , error = Nothing
              }
            , Cmd.none
            , NoOut
            )

        DecisionCompleted _ (Err err) ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
                ( { model
                    | deciding = Nothing
                    , confirming = Nothing
                    , error = Just (decisionError err)
                  }
                , fetch maybeToken
                , NoOut
                )


decide :
    Model
    -> Maybe String
    -> String
    -> (String -> String -> (Result Http.Error () -> Msg) -> Cmd Msg)
    -> ( Model, Cmd Msg, OutMsg )
decide model maybeToken id call =
    case maybeToken of
        Just token ->
            ( { model | deciding = Just id, confirming = Nothing, error = Nothing }
            , call id token (DecisionCompleted id)
            , NoOut
            )

        Nothing ->
            ( model, Cmd.none, NoOut )


removeById : String -> RemoteData Http.Error (List RemovalRequest) -> RemoteData Http.Error (List RemovalRequest)
removeById id requests =
    case requests of
        Success list ->
            Success (List.filter (\r -> r.id /= id) list)

        other ->
            other


{-| Server errors in the reviewer's terms. The 409 is the interesting one: it means the
request was already decided, not that it never existed.
-}
decisionError : Http.Error -> String
decisionError err =
    case err of
        Http.BadStatus 409 ->
            "That request has already been decided — the queue below is up to date."

        Http.BadStatus 404 ->
            "That request no longer exists."

        _ ->
            "Could not record that decision. Please try again."


view : Model -> Html Msg
view model =
    div [ class "page page--admin removal-queue" ]
        [ h1 [ class "page__title admin__title" ] [ text "Removal requests" ]
        , p [ class "admin__subtitle" ]
            [ text
                ("Businesses that asked to be delisted from an address we could not verify "
                    ++ "against their own domain. Every listing below is still live."
                )
            ]
        , case model.error of
            Just message ->
                p [ class "admin__error", testId "removal-queue-error" ] [ text message ]

            Nothing ->
                text ""
        , viewContent model
        ]


viewContent : Model -> Html Msg
viewContent model =
    case model.requests of
        NotAsked ->
            text ""

        Loading ->
            p [ class "admin__loading" ] [ text "Loading…" ]

        Failure _ ->
            p [ class "admin__error" ]
                [ text "Could not load the queue. Refresh to try again." ]

        Success [] ->
            p [ class "admin__empty", testId "removal-queue-empty" ]
                [ text "Nothing waiting. Every removal request has been dealt with." ]

        Success requests ->
            ul [ class "removal-queue__list", testId "removal-queue" ]
                (List.map (viewRequest model) requests)


viewRequest : Model -> RemovalRequest -> Html Msg
viewRequest model request =
    let
        busy =
            model.deciding == Just request.id
    in
    li [ class "removal-queue__row", testId "removal-queue-row" ]
        [ div [ class "removal-queue__detail" ]
            [ span [ class "removal-queue__name" ] [ text request.name ]
            , span [ class "removal-queue__type" ] [ text request.sourceType ]
            , a
                [ class "removal-queue__url"
                , href request.url
                , target "_blank"
                , rel "noopener noreferrer"
                ]
                [ text request.url ]
            , viewAsked request
            ]
        , if model.confirming == Just request.id then
            viewConfirm request busy

          else
            viewActions request busy
        ]


{-| Who asked, and when. The address is what the reviewer is actually judging — whether it
plausibly belongs to the business — so it is not tucked away.
-}
viewAsked : RemovalRequest -> Html Msg
viewAsked request =
    p [ class "removal-queue__asked" ]
        [ text "Asked by "
        , span [ class "removal-queue__email" ]
            [ text (Maybe.withDefault "an address we did not record" request.email) ]
        , case request.requestedAt of
            Just at ->
                span [ class "removal-queue__when" ] [ text (" on " ++ String.left 10 at) ]

            Nothing ->
                text ""
        ]


viewActions : RemovalRequest -> Bool -> Html Msg
viewActions request busy =
    div [ class "removal-queue__actions" ]
        [ button
            [ class "removal-queue__remove"
            , onClick (RemoveClicked request.id)
            , disabled busy
            , testId "removal-queue-remove"
            ]
            [ text "Remove the listing" ]
        , button
            [ class "removal-queue__keep"
            , onClick (KeepClicked request.id)
            , disabled busy
            , testId "removal-queue-keep"
            ]
            [ text "Keep the listing" ]
        ]


{-| The confirmation names the business, so a misplaced click is visible before it lands.
-}
viewConfirm : RemovalRequest -> Bool -> Html Msg
viewConfirm request busy =
    div [ class "removal-queue__confirm", testId "removal-queue-confirm" ]
        [ p [ class "removal-queue__confirm-text" ]
            [ text ("Remove " ++ request.name ++ " from the map? It will not be listed again.") ]
        , button
            [ class "removal-queue__confirm-yes"
            , onClick (RemoveConfirmed request.id)
            , disabled busy
            , testId "removal-queue-confirm-yes"
            ]
            [ text
                (if busy then
                    "Removing…"

                 else
                    "Yes, remove it"
                )
            ]
        , button
            [ class "removal-queue__confirm-no"
            , onClick RemoveCancelled
            , disabled busy
            , testId "removal-queue-confirm-no"
            ]
            [ text "Cancel" ]
        ]
