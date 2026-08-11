module Components.Syndication exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

{-| The Syndication panel — POSSE, stated honestly.

Substack has no write API, so this panel offers exactly what works: the
writer's public blog feed URL (paste into Substack once), a canonical-tagged
copy-for-Substack export, and the "Also published at" field that closes the
loop. Nothing here sends a request to Substack.

Rendered ONLY for the author of a PUBLIC published post. For any other post
the panel is replaced by one honest sentence — the affordances are absent,
not greyed: a greyed button invites a click that will never work.

-}

import Api exposing (Syndication, SyndicationExport)
import Html exposing (Html, a, button, div, h2, input, label, p, span, text, textarea)
import Html.Attributes exposing (checked, class, href, readonly, rel, type_, value)
import Html.Events exposing (onCheck, onClick, onInput, onSubmit)
import Http
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


type CopyTarget
    = Canonical
    | FeedUrl
    | Export String


type CopyState
    = Idle
    | Copied CopyTarget
    | CopyUnavailable String


type alias Model =
    { postId : String
    , origin : String
    , copyState : CopyState
    , pendingCopy : Maybe { target : CopyTarget, payload : String }
    , exportState : RemoteData Http.Error SyndicationExport
    , syndicatedUrlInput : String
    , urlError : Bool
    , savingUrl : Bool
    , syndications : List Syndication
    , includeInFeed : Bool
    }


init : String -> String -> Bool -> Model
init postId origin syndicated =
    { postId = postId
    , origin = origin
    , copyState = Idle
    , pendingCopy = Nothing
    , exportState = NotAsked
    , syndicatedUrlInput = ""
    , urlError = False
    , savingUrl = False
    , syndications = []
    , includeInFeed = syndicated
    }


type Msg
    = ClickedCopyCanonical
    | ClickedCopyFeedUrl String
    | ClickedCopyExport String
    | GotExport String (Result Http.Error SyndicationExport)
    | SyndicationRecorded (Result Http.Error Syndication)
    | UrlChanged String
    | UrlSubmitted
    | UrlSaved (Result Http.Error Syndication)
    | ToggledIncludeInFeed Bool
    | ToggleSaved (Result Http.Error Bool)
    | CopyOutcome Bool


type OutMsg
    = NoOut
    | RequestCopy String
    | SyndicatedChanged Bool
    | AuthLost


canonicalUrl : Model -> String
canonicalUrl model =
    model.origin ++ "/blog/" ++ model.postId


feedUrl : Model -> String -> String
feedUrl model handle =
    model.origin ++ "/api/feeds/u/" ++ handle ++ "/blog"


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        ClickedCopyCanonical ->
            requestCopy model Canonical (canonicalUrl model)

        ClickedCopyFeedUrl url ->
            requestCopy model FeedUrl url

        ClickedCopyExport format ->
            case maybeToken of
                Just token ->
                    ( { model | exportState = Loading }
                    , Api.fetchSyndicationExport token model.postId format (GotExport format)
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, AuthLost )

        GotExport format (Ok export) ->
            ( { model
                | exportState = Success export
                , pendingCopy = Just { target = Export format, payload = export.body }
              }
            , Cmd.none
            , RequestCopy export.body
            )

        GotExport _ (Err err) ->
            ( { model | exportState = Failure err }, Cmd.none, NoOut )

        SyndicationRecorded (Ok syndication) ->
            ( { model | syndications = model.syndications ++ [ syndication ] }
            , Cmd.none
            , NoOut
            )

        SyndicationRecorded (Err _) ->
            ( model, Cmd.none, NoOut )

        UrlChanged value ->
            ( { model | syndicatedUrlInput = value, urlError = False }, Cmd.none, NoOut )

        UrlSubmitted ->
            case ( maybeToken, latestSyndication model ) of
                ( Just token, Just syndication ) ->
                    ( { model | savingUrl = True }
                    , Api.updateSyndicationUrl
                        token
                        model.postId
                        syndication.id
                        model.syndicatedUrlInput
                        UrlSaved
                    , NoOut
                    )

                _ ->
                    ( model, Cmd.none, NoOut )

        UrlSaved (Ok syndication) ->
            ( { model
                | savingUrl = False
                , syndicatedUrlInput = ""
                , syndications = replaceSyndication syndication model.syndications
              }
            , Cmd.none
            , NoOut
            )

        UrlSaved (Err _) ->
            ( { model | savingUrl = False, urlError = True }, Cmd.none, NoOut )

        ToggledIncludeInFeed include ->
            case maybeToken of
                Just token ->
                    ( { model | includeInFeed = include }
                    , Api.setPostSyndicated token model.postId include ToggleSaved
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, AuthLost )

        ToggleSaved (Ok syndicated) ->
            ( { model | includeInFeed = syndicated }, Cmd.none, SyndicatedChanged syndicated )

        ToggleSaved (Err _) ->
            ( { model | includeInFeed = not model.includeInFeed }, Cmd.none, NoOut )

        CopyOutcome True ->
            case model.pendingCopy of
                Just pending ->
                    ( { model | copyState = Copied pending.target, pendingCopy = Nothing }
                    , Cmd.none
                    , NoOut
                    )
                        |> recordIfExport pending maybeToken

                Nothing ->
                    ( model, Cmd.none, NoOut )

        CopyOutcome False ->
            case model.pendingCopy of
                Just pending ->
                    ( { model | copyState = CopyUnavailable pending.payload, pendingCopy = Nothing }
                    , Cmd.none
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )


{-| The view calls this for feed/canonical copies (payload known statically).
-}
requestCopy : Model -> CopyTarget -> String -> ( Model, Cmd Msg, OutMsg )
requestCopy model target payload =
    ( { model | pendingCopy = Just { target = target, payload = payload } }
    , Cmd.none
    , RequestCopy payload
    )


{-| An export that reached the clipboard is a syndication that happened —
record it now, not at fetch time.
-}
recordIfExport :
    { target : CopyTarget, payload : String }
    -> Maybe String
    -> ( Model, Cmd Msg, OutMsg )
    -> ( Model, Cmd Msg, OutMsg )
recordIfExport pending maybeToken ( model, cmd, out ) =
    case ( pending.target, maybeToken ) of
        ( Export _, Just token ) ->
            ( model
            , Cmd.batch [ cmd, Api.recordSyndication token model.postId "export" SyndicationRecorded ]
            , out
            )

        _ ->
            ( model, cmd, out )


latestSyndication : Model -> Maybe Syndication
latestSyndication model =
    List.head (List.reverse model.syndications)


replaceSyndication : Syndication -> List Syndication -> List Syndication
replaceSyndication updated =
    List.map
        (\s ->
            if s.id == updated.id then
                updated

            else
                s
        )


{-| `handle` is the author's public handle (the feed URL needs it);
`isPublicPublished` decides panel vs the honest replacement sentence.
-}
view : Model -> String -> Bool -> Html Msg
view model handle isPublicPublished =
    if isPublicPublished then
        viewPanel model handle

    else
        div [ class "post__syndication post__syndication-unavailable", testId "syndication-unavailable" ]
            [ p []
                [ text "This post is not public, so there is nothing to syndicate. Syndication sends a piece to a place with no idea who your readers are — only public posts can go." ]
            ]


viewPanel : Model -> String -> Html Msg
viewPanel model handle =
    div [ class "post__syndication", testId "syndication-panel" ]
        [ h2 [ class "post__syndication-heading" ] [ text "Syndication" ]
        , viewCopyStatus model
        , viewCanonical model
        , viewActions model
        , viewFeedSection model handle
        , viewAlsoPublishedAt model
        , viewIncludeInFeed model
        , viewCopyFallback model
        , p [ class "post__syndication-caption" ]
            [ text "Syndication is a copy, not a mirror. If you edit or delete this post here, the Substack copy stays as it was — you'd need to change it there too." ]
        ]


viewCanonical : Model -> Html Msg
viewCanonical model =
    div [ class "post__syndication-canonical" ]
        [ span [ class "post__syndication-label" ] [ text "Canonical address" ]
        , span [ class "post__syndication-url", testId "syndication-canonical-url" ]
            [ text (canonicalUrl model) ]
        , button
            [ class "post__syndication-copy"
            , testId "syndication-canonical-copy"
            , onClick ClickedCopyCanonical
            ]
            [ text (copyLabel model Canonical "Copy") ]
        , p [ class "post__syndication-note" ]
            [ text "This is where this piece lives. Anywhere else it appears should point back here." ]
        ]


viewActions : Model -> Html Msg
viewActions model =
    div [ class "post__syndication-actions" ]
        [ span [ class "post__syndication-label" ] [ text "Copy for Substack" ]
        , button
            [ class "post__syndication-copy"
            , testId "syndication-export-markdown"
            , onClick (ClickedCopyExport "markdown")
            ]
            [ text (copyLabel model (Export "markdown") "Markdown") ]
        , button
            [ class "post__syndication-copy"
            , testId "syndication-export-html"
            , onClick (ClickedCopyExport "html")
            ]
            [ text (copyLabel model (Export "html") "HTML") ]
        , case model.exportState of
            Failure _ ->
                span [ class "post__syndication-error" ]
                    [ text "Couldn't fetch that — try again." ]

            _ ->
                text ""
        ]


viewFeedSection : Model -> String -> Html Msg
viewFeedSection model handle =
    if handle == "" then
        text ""

    else
        div [ class "post__syndication-feed" ]
            [ span [ class "post__syndication-label" ] [ text "Your blog feed" ]
            , span [ class "post__syndication-url", testId "syndication-feed-url" ]
                [ text (feedUrl model handle) ]
            , button
                [ class "post__syndication-copy"
                , testId "syndication-feed-copy"
                , onClick (ClickedCopyFeedUrl (feedUrl model handle))
                ]
                [ text (copyLabel model FeedUrl "Copy") ]
            , p [ class "post__syndication-note" ]
                [ text "Paste this into Substack once, under Settings → Import → RSS. Every public post you write from then on arrives there as a draft." ]
            ]


viewIncludeInFeed : Model -> Html Msg
viewIncludeInFeed model =
    div [ class "post__syndication-toggle" ]
        [ label []
            [ input
                [ type_ "checkbox"
                , checked model.includeInFeed
                , onCheck ToggledIncludeInFeed
                , testId "syndication-include-toggle"
                ]
                []
            , text " Include this post in my public feed"
            ]
        , p [ class "post__syndication-note" ]
            [ text "Unticking this keeps the post public on The Stacks but takes it out of the feed Substack reads. Already-syndicated copies stay where they are." ]
        ]


viewAlsoPublishedAt : Model -> Html Msg
viewAlsoPublishedAt model =
    case backlink model of
        Just url ->
            div [ class "post__syndication-backlink" ]
                [ span [ class "post__syndication-label" ] [ text "Also published at" ]
                , a
                    [ href url
                    , rel "nofollow noopener"
                    , testId "syndication-backlink"
                    ]
                    [ text url ]
                ]

        Nothing ->
            if model.syndications == [] then
                text ""

            else
                Html.form [ class "post__syndication-backlink", onSubmit UrlSubmitted ]
                    [ label [ class "post__syndication-label" ]
                        [ text "Also published at" ]
                    , input
                        [ type_ "url"
                        , value model.syndicatedUrlInput
                        , onInput UrlChanged
                        , testId "syndication-also-at-input"
                        ]
                        []
                    , button
                        [ class "post__syndication-copy", type_ "submit" ]
                        [ text
                            (if model.savingUrl then
                                "Saving…"

                             else
                                "Save"
                            )
                        ]
                    , if model.urlError then
                        span [ class "post__syndication-error" ]
                            [ text "That doesn't look like a web address." ]

                      else
                        text ""
                    ]


{-| The copy confirmation, announced through an aria-live region rather than
by mutating the button label alone — so a screen-reader user learns the copy
happened (story §12 ARIA note).
-}
viewCopyStatus : Model -> Html Msg
viewCopyStatus model =
    div
        [ class "post__syndication-status"
        , Html.Attributes.attribute "aria-live" "polite"
        ]
        [ case model.copyState of
            Copied (Export format) ->
                text ("Copied the " ++ format ++ " export — paste it into Substack.")

            Copied Canonical ->
                text "Canonical address copied."

            Copied FeedUrl ->
                text "Feed URL copied — paste it into Substack under Settings → Import → RSS."

            _ ->
                text ""
        ]


viewCopyFallback : Model -> Html Msg
viewCopyFallback model =
    case model.copyState of
        CopyUnavailable payload ->
            div [ class "post__syndication-fallback" ]
                [ p [] [ text "Your browser wouldn't let us copy — select all and copy:" ]
                , textarea
                    [ readonly True
                    , value payload
                    , testId "syndication-copy-fallback"
                    ]
                    []
                ]

        _ ->
            text ""


backlink : Model -> Maybe String
backlink model =
    model.syndications
        |> List.filterMap .syndicatedUrl
        |> List.head


copyLabel : Model -> CopyTarget -> String -> String
copyLabel model target idle =
    case model.copyState of
        Copied copied ->
            if copied == target then
                "Copied — paste it into Substack"

            else
                idle

        _ ->
            idle
