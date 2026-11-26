module Page.BlogPostEffectTest exposing (suite)

{-| What opening a blog post actually asks the server for.

⛔ **IMPOSSIBLE BEFORE THE SEAM.** `Page.Blog.Post` built eleven request plans
and performed them itself, so none escaped the module and the harness could not
read any of them. It was the module that gained the MOST plans in the request
migration and simultaneously the one least able to be tested — which is the
shape the stack review called out: the migration was 40% of an architecture, and
the modules furthest from the seam were the ones that changed most.

⚖️ Asserting on the plans as data, not on a simulated response. The thing that
was missing is the ability to see the requests at all; a `ProgramTest` driving
responses would assert something real but would not demonstrate that.

-}

import Api
import Api.Url
import Effect
import Expect
import Page.Blog.Post as Post
import Test exposing (Test, describe, test)
import TestHelpers


{-| Every request a plan tree holds, in order.

⚠️ Recurses through `Batch` rather than looking only at the top: `init` returns
its two requests batched, so a helper that read only `Effect.Request` would
report none and every assertion below would be vacuously about an empty list.

-}
plansIn : Effect.Effect msg -> List Api.RequestSpec
plansIn effect =
    case effect of
        Effect.Request plan ->
            [ plan.spec ]

        Effect.Batch effects ->
            List.concatMap plansIn effects

        _ ->
            []


openingThePost : Effect.Effect Post.Msg
openingThePost =
    Tuple.second (Post.initWithEffect "post-9" Nothing Nothing "https://stacks.test")


{-| The effect of submitting a comment, from whatever state `init` left behind.

⚠️ Goes through `updateWithEffect` rather than `init`, because `update` is where
ten of this module's eleven plans live — and they were the ones no harness could
see.

-}
submittingAComment : Maybe Api.Credentials -> Effect.Effect Post.Msg
submittingAComment maybeToken =
    let
        ( model, _ ) =
            Post.initWithEffect "post-9" maybeToken Nothing "https://stacks.test"

        ( drafted, _, _ ) =
            Post.updateWithEffect (Post.CommentDraftChanged "a thought") model maybeToken

        ( _, effect, _ ) =
            Post.updateWithEffect Post.SubmitComment drafted maybeToken
    in
    effect


suite : Test
suite =
    describe "Page.Blog.Post, read as data"
        [ test "opening a post asks for the post and its comments, in that order" <|
            \() ->
                plansIn openingThePost
                    |> List.map (.url >> Api.Url.toString)
                    |> Expect.equal
                        [ "/api/blog/posts/post-9"
                        , "/api/posts/post-9/comments"
                        ]

        -- ⛔ ANTI-VACUITY: `plansIn` returning `[]` would satisfy a
        -- `List.member`-style assertion and most "contains" shapes. Pinning the
        -- count means an empty tree — the state before the seam — fails here.
        , test "and it asks for exactly those two things" <|
            \() ->
                plansIn openingThePost
                    |> List.length
                    |> Expect.equal 2

        -- ⚖️ Both are reads. A write slipping into page load is the kind of
        -- thing that was unobservable while the plans stayed inside `update`.
        , test "opening a post writes nothing" <|
            \() ->
                plansIn openingThePost
                    |> List.map .method
                    |> Expect.equal [ "GET", "GET" ]

        -- ⛔ A PLAN FROM `update`, WHICH IS WHERE TEN OF THE ELEVEN LIVE. The
        -- `init` cases above would pass against a module whose `update` still
        -- performed its own effects; this one would not.
        , test "submitting a comment posts it to that post's comments" <|
            \() ->
                submittingAComment (Just (TestHelpers.creds "tok"))
                    |> plansIn
                    |> List.map (\spec -> ( spec.method, Api.Url.toString spec.url ))
                    |> Expect.equal [ ( "POST", "/api/posts/post-9/comments" ) ]

        -- ⚖️ Not redundant with the case above: a module that built the plan
        -- regardless of session would pass it while sending a write the server
        -- can only refuse.
        , test "a signed-out reader submits nothing" <|
            \() ->
                submittingAComment Nothing
                    |> plansIn
                    |> Expect.equal []
        ]
