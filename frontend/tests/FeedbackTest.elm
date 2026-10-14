module FeedbackTest exposing (suite)

{-| The reader's feedback form and the owner's queue.

Two properties carry the weight here. A failed send must keep the draft — the
alternative silently destroys the only copy of something a reader took trouble
over. And the captured page context must be a route PATTERN: `/u/:handle`, not
`/u/mara`, because the concrete path names a reader who was never part of the
conversation.

-}

import Api
import Expect
import Html.Attributes as Attr
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Navigation.Route as Route exposing (ConfirmStatus(..), Route(..))
import Page.Admin.Feedback as AdminQueue
import Page.Feedback as Feedback
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.RemoteData exposing (RemoteData(..))


testId : String -> Selector.Selector
testId value =
    Selector.attribute (Attr.attribute "data-testid" value)


update : Feedback.Msg -> Feedback.Model -> ( Feedback.Model, Cmd Feedback.Msg )
update msg model =
    let
        ( newModel, cmd, _ ) =
            Feedback.update msg model (Just "token")
    in
    ( newModel, cmd )


written : String -> Feedback.Model
written message =
    Tuple.first (update (Feedback.MessageChanged message) (Feedback.init "/library"))


render : Feedback.Model -> Query.Single Feedback.Msg
render model =
    Feedback.view model |> Query.fromHtml


entry : String -> Api.AdminFeedbackEntry
entry body =
    { id = "fb-" ++ body
    , body = body
    , pageContext = Just "/u/:handle"
    , senderHandle = Just "mara"
    , createdAt = "2026-08-18T09:30:00Z"
    }


{-| A loaded queue showing `entries` out of `total`, from the first page.
-}
queue : List Api.AdminFeedbackEntry -> Int -> AdminQueue.Model
queue entries total =
    queueAt 0 (Success { entries = entries, total = total })


queueAt : Int -> RemoteData Http.Error Api.AdminFeedbackPage -> AdminQueue.Model
queueAt offset page =
    { page = page, offset = offset }


adminUpdate :
    AdminQueue.Msg
    -> AdminQueue.Model
    -> ( AdminQueue.Model, Cmd AdminQueue.Msg, AdminQueue.OutMsg )
adminUpdate msg model =
    AdminQueue.update msg model (Just "token")


{-| Every route with an argument, given an argument no path segment could be
mistaken for. `toPattern` must not echo it back.
-}
parameterisedRoutes : List Route
parameterisedRoutes =
    [ BookDetail "SENTINEL"
    , MarketplaceDetail "SENTINEL"
    , BlogEdit "SENTINEL"
    , BlogPost "SENTINEL"
    , GroupDetail "SENTINEL"
    , Profile "SENTINEL"
    , ProfileShelf "SENTINEL" "SENTINEL"
    , ResetPassword "SENTINEL"
    , ConfirmEmail EmailConfirmed
    ]


suite : Test
suite =
    describe "Beta feedback channel"
        [ describe "the send button is honest about when it will work"
            [ test "an empty box cannot be sent" <|
                \_ ->
                    render (Feedback.init "/library")
                        |> Query.find [ testId "feedback-send" ]
                        |> Query.has [ Selector.disabled True ]
            , test "whitespace is not a message" <|
                \_ ->
                    render (written "    ")
                        |> Query.find [ testId "feedback-send" ]
                        |> Query.has [ Selector.disabled True ]
            , test "a real message enables it" <|
                \_ ->
                    render (written "The spines overlap on the wishlist.")
                        |> Query.find [ testId "feedback-send" ]
                        |> Query.has [ Selector.disabled False ]
            , test "an over-long message disables it and says why" <|
                \_ ->
                    render (written (String.repeat 5001 "a"))
                        |> Expect.all
                            [ Query.find [ testId "feedback-send" ]
                                >> Query.has [ Selector.disabled True ]
                            , Query.has [ testId "feedback-too-long" ]
                            ]
            , test "clicking send with an empty box fires nothing" <|
                \_ ->
                    let
                        ( model, _ ) =
                            update Feedback.SendClicked (Feedback.init "/library")
                    in
                    Expect.equal NotAsked model.sending
            ]
        , describe "the outcome is never guessed at"
            [ test "nothing is claimed before a send" <|
                \_ ->
                    render (Feedback.init "/library")
                        |> Expect.all
                            [ Query.hasNot [ testId "feedback-sent" ]
                            , Query.hasNot [ testId "feedback-failed" ]
                            ]
            , test "a success says so, and clears the box" <|
                \_ ->
                    let
                        ( model, _ ) =
                            update (Feedback.SendCompleted (Ok ())) (written "Something broke.")
                    in
                    Expect.all
                        [ \m -> Expect.equal (Success ()) m.sending
                        , \m -> Expect.equal "" m.message
                        , \m -> render m |> Query.has [ testId "feedback-sent" ]
                        ]
                        model
            , test "a failure does NOT look like a success" <|
                \_ ->
                    let
                        ( model, _ ) =
                            update (Feedback.SendCompleted (Err Http.NetworkError))
                                (written "Something broke.")
                    in
                    render model
                        |> Expect.all
                            [ Query.has [ testId "feedback-failed" ]
                            , Query.hasNot [ testId "feedback-sent" ]
                            ]
            , test "a rate limit is explained as a rate limit, not as a breakage" <|
                \_ ->
                    let
                        ( model, _ ) =
                            update (Feedback.SendCompleted (Err (Http.BadStatus 429)))
                                (written "My third report today.")
                    in
                    render model
                        |> Query.has [ Selector.text "You've sent a few already" ]
            ]
        , describe "a failed send keeps the draft — the whole point"
            [ test "the message survives a network failure" <|
                \_ ->
                    let
                        ( model, _ ) =
                            update (Feedback.SendCompleted (Err Http.NetworkError))
                                (written "An hour of careful notes.")
                    in
                    Expect.equal "An hour of careful notes." model.message
            , test "the message survives a rate limit" <|
                \_ ->
                    let
                        ( model, _ ) =
                            update (Feedback.SendCompleted (Err (Http.BadStatus 429)))
                                (written "An hour of careful notes.")
                    in
                    Expect.equal "An hour of careful notes." model.message
            , test "the textarea still shows it, not just the model" <|
                \_ ->
                    let
                        ( model, _ ) =
                            update (Feedback.SendCompleted (Err Http.NetworkError))
                                (written "An hour of careful notes.")
                    in
                    render model
                        |> Query.find [ testId "feedback-message" ]
                        |> Query.has [ Selector.attribute (Attr.value "An hour of careful notes.") ]
            ]
        , describe "the request carries the message and the context, and nothing else"
            [ test "it names the endpoint and sends exactly two fields" <|
                \_ ->
                    Expect.equal
                        { method = "POST"
                        , url = "/api/feedback"
                        , body =
                            Just
                                (Encode.object
                                    [ ( "body", Encode.string "The spines overlap." )
                                    , ( "page_context", Encode.string "/u/:handle" )
                                    ]
                                )
                        }
                        (Api.sendFeedbackRequest
                            { body = "The spines overlap.", pageContext = "/u/:handle" }
                        )
            ]
        , describe "the captured context is a pattern, never someone's handle"
            [ test "a profile becomes /u/:handle" <|
                \_ ->
                    Expect.equal "/u/:handle" (Route.toPattern (Profile "mara"))
            , test "no parameterised route echoes its argument back" <|
                \_ ->
                    parameterisedRoutes
                        |> List.filter (\r -> String.contains "SENTINEL" (Route.toPattern r))
                        |> List.map Route.toPath
                        |> Expect.equalLists []
            , test "an argument-free route keeps its own path" <|
                \_ ->
                    Expect.equal "/library" (Route.toPattern Library)
            ]
        , describe "the owner's queue distinguishes empty from broken"
            [ test "renders one row per message" <|
                \_ ->
                    AdminQueue.view (queue [ entry "one", entry "two" ] 2)
                        |> Query.fromHtml
                        |> Query.findAll [ testId "admin-feedback-entry" ]
                        |> Query.count (Expect.equal 2)
            , test "shows what the reader actually wrote" <|
                \_ ->
                    AdminQueue.view (queue [ entry "The bookcase breaks at 320px." ] 1)
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "The bookcase breaks at 320px." ]
            , test "shows who wrote it" <|
                \_ ->
                    AdminQueue.view (queue [ entry "one" ] 1)
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "@mara" ]
            , test "an empty queue says so" <|
                \_ ->
                    AdminQueue.view (queue [] 0)
                        |> Query.fromHtml
                        |> Query.has [ testId "admin-feedback-empty" ]
            , test "a failed load does NOT read as an empty queue" <|
                \_ ->
                    AdminQueue.view (queueAt 0 (Failure Http.NetworkError))
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has [ testId "admin-feedback-error" ]
                            , Query.hasNot [ testId "admin-feedback-empty" ]
                            ]
            , test "a loaded response fills the queue" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            adminUpdate
                                (AdminQueue.EntriesReceived
                                    (Ok { entries = [ entry "one" ], total = 1 })
                                )
                                (queueAt 0 Loading)
                    in
                    Expect.equal (Success { entries = [ entry "one" ], total = 1 }) model.page
            , test "a lapsed admin session bubbles out rather than rendering an error" <|
                \_ ->
                    let
                        ( _, _, out ) =
                            adminUpdate
                                (AdminQueue.EntriesReceived (Err (Http.BadStatus 401)))
                                (queueAt 0 Loading)
                    in
                    Expect.equal AdminQueue.SessionExpired out
            , test "an ordinary failure stays on the page" <|
                \_ ->
                    let
                        ( _, _, out ) =
                            adminUpdate
                                (AdminQueue.EntriesReceived (Err Http.NetworkError))
                                (queueAt 0 Loading)
                    in
                    Expect.equal AdminQueue.NoOut out
            ]
        , describe "the owner can reach feedback older than one page"
            [ test "the page states the window it is showing out of the whole queue" <|
                \_ ->
                    AdminQueue.view (queue [ entry "one", entry "two" ] 143)
                        |> Query.fromHtml
                        |> Query.find [ testId "admin-feedback-count" ]
                        |> Query.has [ Selector.text "Showing 1–2 of 143" ]
            , test "a later window counts from its own offset, not from one" <|
                \_ ->
                    AdminQueue.view
                        (queueAt AdminQueue.pageSize
                            (Success { entries = [ entry "one" ], total = 143 })
                        )
                        |> Query.fromHtml
                        |> Query.find [ testId "admin-feedback-count" ]
                        |> Query.has [ Selector.text "Showing 26–26 of 143" ]
            , test "older feedback is reachable when the total exceeds the window" <|
                \_ ->
                    AdminQueue.view (queue [ entry "one" ] 143)
                        |> Query.fromHtml
                        |> Query.has [ testId "admin-feedback-older" ]
            , test "a full page with nothing behind it offers no older control at all" <|
                \_ ->
                    -- ABSENT, not disabled. A dead button in this stylesheet is
                    -- indistinguishable from a live one — `.btn` has no
                    -- `:disabled` rule and `.btn--secondary` paints over the
                    -- browser's grey — so it would invite a click that does
                    -- nothing and explains nothing.
                    AdminQueue.view (queue (List.repeat 25 (entry "one")) 25)
                        |> Query.fromHtml
                        |> Query.hasNot [ testId "admin-feedback-older" ]
            , test "the first window offers no newer control at all" <|
                \_ ->
                    AdminQueue.view (queue [ entry "one" ] 143)
                        |> Query.fromHtml
                        |> Query.hasNot [ testId "admin-feedback-newer" ]
            , test "a queue that fits in one window shows no pager" <|
                \_ ->
                    AdminQueue.view (queue [ entry "one", entry "two" ] 2)
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.hasNot [ testId "admin-feedback-newer" ]
                            , Query.hasNot [ testId "admin-feedback-older" ]
                            ]
            , test "a failed refetch at a later window still offers the way back" <|
                \_ ->
                    -- Otherwise the owner is stranded: an error with no pager, on
                    -- the only surface that can read feedback, and the sole escape
                    -- is navigating away — which silently returns them to the
                    -- newest page as if nothing had happened.
                    AdminQueue.view (queueAt AdminQueue.pageSize (Failure Http.NetworkError))
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has [ testId "admin-feedback-error" ]
                            , Query.has [ testId "admin-feedback-newer" ]
                            ]
            , test "asking for older feedback moves the window past what was shown" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            adminUpdate AdminQueue.ClickedOlder
                                (queue (List.repeat AdminQueue.pageSize (entry "one")) 143)
                    in
                    Expect.equal AdminQueue.pageSize model.offset
            , test "a short page advances by what arrived, not by what was asked for" <|
                \_ ->
                    -- The window advances on the server's actual answer. Asking
                    -- for 25 and being given 10 means the next window starts at
                    -- 10; advancing by 25 would skip fifteen entries that were
                    -- never shown, on the only interface that can read them.
                    let
                        ( model, _, _ ) =
                            adminUpdate AdminQueue.ClickedOlder
                                (queue (List.repeat 10 (entry "one")) 143)
                    in
                    Expect.equal 10 model.offset
            , test "asking for older feedback at the end of the queue stays put" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            adminUpdate AdminQueue.ClickedOlder (queue [ entry "one" ] 1)
                    in
                    Expect.equal 0 model.offset
            , test "coming back from a later window never goes past the start" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            adminUpdate AdminQueue.ClickedNewer
                                (queueAt AdminQueue.pageSize
                                    (Success { entries = [ entry "one" ], total = 143 })
                                )
                    in
                    Expect.equal 0 model.offset
            , test "a window past the end of the queue does not read as an empty queue" <|
                \_ ->
                    AdminQueue.view
                        (queueAt (AdminQueue.pageSize * 4)
                            (Success { entries = [], total = 10 })
                        )
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.hasNot [ testId "admin-feedback-empty" ]
                            , Query.has [ Selector.text "10 in total" ]
                            ]
            , test "coming back from a window that is not a whole page lands on the start" <|
                \_ ->
                    -- From offset 10 the arithmetic is 10 - 25 = -15, so this is
                    -- the only case that exercises the floor at all. The
                    -- previous test starts at exactly one page, where 25 - 25 is
                    -- already 0 and the floor is never reached — its name
                    -- claimed cover it did not have.
                    let
                        ( model, _, _ ) =
                            adminUpdate AdminQueue.ClickedNewer
                                (queueAt 10 (Success { entries = [ entry "one" ], total = 143 }))
                    in
                    Expect.equal 0 model.offset
            ]
        , describe "the window actually reaches the server"
            [ test "the request names the endpoint and carries the window it was given" <|
                \_ ->
                    -- The one piece of this change nothing else could reach. An
                    -- off-by-one here serves the same page forever and every
                    -- paging test above still passes, because they assert the
                    -- model and never the request.
                    Expect.equal
                        { method = "GET"
                        , url = "/api/admin/feedback?limit=25&offset=50"
                        , body = Nothing
                        }
                        (Api.adminFeedbackRequest { limit = 25, offset = 50 })
            , test "the first window asks for offset zero rather than omitting it" <|
                \_ ->
                    Expect.equal "/api/admin/feedback?limit=25&offset=0"
                        (Api.adminFeedbackRequest { limit = 25, offset = 0 }).url
            ]
        , describe "the queue response decodes"
            [ test "a populated page carries its entries and the whole-queue total" <|
                \_ ->
                    case
                        Decode.decodeString Api.adminFeedbackPageDecoder
                            """
                            { "feedback": [ { "id": "f1", "body": "The spines overlap.",
                                              "page_context": "wishlist",
                                              "sender_handle": "mara",
                                              "created_at": "2026-08-18T09:30:00Z" } ],
                              "total": 143 }
                            """
                    of
                        Ok page ->
                            Expect.equal ( 1, 143 ) ( List.length page.entries, page.total )

                        Err err ->
                            Expect.fail (Decode.errorToString err)
            , test "an empty page with a non-zero total decodes — that is a window past the end" <|
                \_ ->
                    case
                        Decode.decodeString Api.adminFeedbackPageDecoder
                            """{ "feedback": [], "total": 10 }"""
                    of
                        Ok page ->
                            Expect.equal ( 0, 10 ) ( List.length page.entries, page.total )

                        Err err ->
                            Expect.fail (Decode.errorToString err)
            , test "a response with no total is a decode failure" <|
                \_ ->
                    -- Without this, renaming the server's `total` to anything
                    -- else leaves the page saying "could not load the feedback"
                    -- forever with the whole suite green.
                    case
                        Decode.decodeString Api.adminFeedbackPageDecoder
                            """{ "feedback": [] }"""
                    of
                        Ok _ ->
                            Expect.fail "total must stay required — the count is the point"

                        Err _ ->
                            Expect.pass
            ]
        , describe "the invitation code never travels in the URL"
            [ test "the lookup is a POST and the code is in the body" <|
                \_ ->
                    -- The reason this endpoint is a POST at all: a code in the
                    -- path is written into the request log on every attempt.
                    -- Nothing else pins that, so a later refactor could put it
                    -- back with no test failing.
                    let
                        spec =
                            Api.checkInviteRequest "STK-ABCD-1234"
                    in
                    Expect.all
                        [ \s -> Expect.equal "POST" s.method
                        , \s ->
                            Expect.equal False (String.contains "STK-ABCD-1234" s.url)
                        , \s ->
                            Expect.equal
                                (Just
                                    (Encode.object
                                        [ ( "code", Encode.string "STK-ABCD-1234" ) ]
                                    )
                                )
                                s.body
                        ]
                        spec
            ]
        ]
