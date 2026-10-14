module Page.Admin.Feedback exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , pageSize
    , update
    , view
    )

{-| The owner's feedback queue — the only surface in the SPA that renders what
readers wrote.

An empty queue and a failed load are drawn differently on purpose. "Nobody has
written yet" and "we could not ask" look identical if both fall through to the
same blank panel, and the second one silently reads as the first — which is how
a broken admin page goes unnoticed for a week.

The queue is PAGED, and the count is part of the page rather than a nicety. This
is the only interface that can read feedback, so anything outside the window it
asks for is unreachable, and the end that falls outside is the oldest — the
feedback most likely to have gone unanswered. A window with no total beside it
cannot tell a full page from a truncated queue.

-}

import Api exposing (AdminFeedbackEntry, AdminFeedbackPage)
import Html exposing (Html, button, div, h1, li, p, span, text, ul)
import Html.Attributes exposing (attribute, class)
import Html.Events exposing (onClick)
import Http
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


{-| Entries per request. Smaller than the server's default of 100 because this
is free text being read, not rows being scanned.
-}
pageSize : Int
pageSize =
    25


{-| No token here, deliberately. Every sibling admin page takes it as `update`'s
third argument, read fresh from one place on each dispatch, and the function
that supplies it carries a post-mortem of what a second copy cost: it drifted,
and every admin action 401'd behind a page that still looked loaded.
-}
type alias Model =
    { page : RemoteData Http.Error AdminFeedbackPage
    , offset : Int
    }


type Msg
    = EntriesReceived (Result Http.Error AdminFeedbackPage)
    | ClickedOlder
    | ClickedNewer


type OutMsg
    = NoOut
    | SessionExpired


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    ( { page = Loading, offset = 0 }
    , fetch maybeToken 0
    )


fetch : Maybe String -> Int -> Cmd Msg
fetch maybeToken offset =
    case maybeToken of
        Just token ->
            Api.getAdminFeedback token
                { limit = pageSize, offset = offset }
                EntriesReceived

        Nothing ->
            Cmd.none


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        EntriesReceived (Ok page) ->
            ( { model | page = Success page }, Cmd.none, NoOut )

        EntriesReceived (Err err) ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
                ( { model | page = Failure err }, Cmd.none, NoOut )

        ClickedOlder ->
            if hasOlder model then
                let
                    -- Advanced by what the server ACTUALLY returned, not by the
                    -- page size we asked for. The two agree today because the
                    -- server honours a limit of 25, but a change to its clamp
                    -- would silently skip or repeat rows; counting what arrived
                    -- is right whenever there is a next page at all.
                    offset =
                        model.offset + shownCount model
                in
                ( { model | offset = offset, page = Loading }
                , fetch maybeToken offset
                , NoOut
                )

            else
                ( model, Cmd.none, NoOut )

        ClickedNewer ->
            if hasNewer model then
                let
                    offset =
                        max 0 (model.offset - pageSize)
                in
                ( { model | offset = offset, page = Loading }
                , fetch maybeToken offset
                , NoOut
                )

            else
                ( model, Cmd.none, NoOut )


{-| True when the queue holds entries past the window currently shown. Answered
from `total`, not from whether the page came back full: a queue of exactly 25
returns a full page with nothing behind it.
-}
hasOlder : Model -> Bool
hasOlder model =
    case model.page of
        Success page ->
            model.offset + List.length page.entries < page.total

        _ ->
            False


{-| True when there is a window before this one. One function rather than a
predicate written twice in two polarities, which is how the view's copy and the
update's copy drift apart.
-}
hasNewer : Model -> Bool
hasNewer model =
    model.offset > 0


{-| How many entries the current window actually returned.
-}
shownCount : Model -> Int
shownCount model =
    case model.page of
        Success page ->
            List.length page.entries

        _ ->
            0


view : Model -> Html Msg
view model =
    div [ class "page page--admin" ]
        [ h1 [ class "page__title" ] [ text "Feedback" ]
        , case model.page of
            Success page ->
                if List.isEmpty page.entries && page.total == 0 then
                    p [ class "admin__empty", testId "admin-feedback-empty" ]
                        [ text "Nothing has come in yet." ]

                else
                    div []
                        [ viewCount model page
                        , ul [ class "admin-feedback__list" ]
                            (List.map viewEntry page.entries)
                        ]

            Failure _ ->
                p [ class "admin__error", testId "admin-feedback-error" ]
                    [ text "Could not load the feedback." ]

            _ ->
                p [ class "admin__loading" ] [ text "Loading…" ]

        -- OUTSIDE the case, deliberately. A failed refetch at a non-zero offset
        -- would otherwise leave the owner on a page with an error and no way
        -- back, on the only surface that can read feedback at all — and the way
        -- out would be to navigate away, which silently resets to the newest
        -- page. "Newer" needs nothing from the response to be correct.
        , viewPager model
        ]


{-| "Showing 1–25 of 143". The range is stated rather than implied so the owner
can see at a glance that there is older feedback behind this page.
-}
viewCount : Model -> AdminFeedbackPage -> Html Msg
viewCount model page =
    let
        shown =
            List.length page.entries

        label =
            if shown == 0 then
                "No feedback on this page · " ++ String.fromInt page.total ++ " in total"

            else
                "Showing "
                    ++ String.fromInt (model.offset + 1)
                    ++ "–"
                    ++ String.fromInt (model.offset + shown)
                    ++ " of "
                    ++ String.fromInt page.total
    in
    -- `aria-live` because paging replaces the list underneath a reader who
    -- cannot see it change; this line is the only thing that says where they
    -- now are. The existing pager's class is reused rather than a second one
    -- invented for the same job.
    p
        [ class "admin__page-info admin-feedback__count"
        , attribute "aria-live" "polite"
        , testId "admin-feedback-count"
        ]
        [ text label ]


{-| The two controls, each rendered only when it leads somewhere.

Absent rather than disabled, which is this project's settled answer for an
affordance that cannot act: a greyed button invites a click that will never
work, and in this stylesheet it would not even read as greyed — `.btn` has no
`:disabled` rule, and `.btn--secondary` paints the accent border and accent
text over the browser's own grey, so a dead button looks exactly like a live
one. The admin moderation pager omits its controls for the same reason.

-}
viewPager : Model -> Html Msg
viewPager model =
    let
        newer =
            hasNewer model

        older =
            hasOlder model
    in
    if not newer && not older then
        text ""

    else
        div [ class "admin__pagination" ]
            [ if newer then
                button
                    [ class "btn btn--secondary btn--sm"
                    , testId "admin-feedback-newer"
                    , onClick ClickedNewer
                    ]
                    [ text "Newer" ]

              else
                text ""
            , if older then
                button
                    [ class "btn btn--secondary btn--sm"
                    , testId "admin-feedback-older"
                    , onClick ClickedOlder
                    ]
                    [ text "Older" ]

              else
                text ""
            ]


viewEntry : AdminFeedbackEntry -> Html Msg
viewEntry entry =
    li [ class "admin-feedback__entry", testId "admin-feedback-entry" ]
        [ div [ class "admin-feedback__meta" ]
            [ span [ class "admin-feedback__sender" ] [ text (senderLabel entry) ]
            , span [ class "admin-feedback__context" ] [ text (contextLabel entry) ]
            , span [ class "admin-feedback__when" ] [ text entry.createdAt ]
            ]
        , p [ class "admin-feedback__body" ] [ text entry.body ]
        ]


senderLabel : AdminFeedbackEntry -> String
senderLabel entry =
    case entry.senderHandle of
        Just handle ->
            "@" ++ handle

        Nothing ->
            "no handle"


contextLabel : AdminFeedbackEntry -> String
contextLabel entry =
    case entry.pageContext of
        Just context ->
            context

        Nothing ->
            "—"
