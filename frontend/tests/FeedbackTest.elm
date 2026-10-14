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
    { page = page, offset = offset, token = Just "token" }


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
                            AdminQueue.update
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
                            AdminQueue.update
                                (AdminQueue.EntriesReceived (Err (Http.BadStatus 401)))
                                (queueAt 0 Loading)
                    in
                    Expect.equal AdminQueue.SessionExpired out
            , test "an ordinary failure stays on the page" <|
                \_ ->
                    let
                        ( _, _, out ) =
                            AdminQueue.update
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
                        |> Query.find [ testId "admin-feedback-older" ]
                        |> Query.hasNot [ Selector.disabled True ]
            , test "a full page with nothing behind it offers no older page" <|
                \_ ->
                    AdminQueue.view (queue (List.repeat 25 (entry "one")) 25)
                        |> Query.fromHtml
                        |> Query.find [ testId "admin-feedback-older" ]
                        |> Query.has [ Selector.disabled True ]
            , test "the first window offers no newer page" <|
                \_ ->
                    AdminQueue.view (queue [ entry "one" ] 143)
                        |> Query.fromHtml
                        |> Query.find [ testId "admin-feedback-newer" ]
                        |> Query.has [ Selector.disabled True ]
            , test "asking for older feedback moves the window a page on" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            AdminQueue.update AdminQueue.ShowOlder (queue [ entry "one" ] 143)
                    in
                    Expect.equal AdminQueue.pageSize model.offset
            , test "asking for older feedback at the end of the queue stays put" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            AdminQueue.update AdminQueue.ShowOlder (queue [ entry "one" ] 1)
                    in
                    Expect.equal 0 model.offset
            , test "coming back from a later window never goes past the start" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            AdminQueue.update AdminQueue.ShowNewer
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
            ]
        ]
