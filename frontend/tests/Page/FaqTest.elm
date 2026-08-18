module Page.FaqTest exposing (suite)

{-| Oracle for the public FAQ.

Two things here are contracts rather than copy, and are asserted as such:

1.  **The published question ids.** Each is a citable anchor, so dropping or
    renaming one breaks somebody's bookmark. `publishedQuestionIds` is the
    list, asserted whole — a question may gain a better wording, but not a
    different id.
2.  **Every answer ships expanded.** A collapsed answer cannot be found by the
    browser's own search, which is how a reference page is actually read, so
    "open by default" is the behaviour and collapsing is the opt-in.

The closed-beta answer is driven from the server's `inviteOnly` flag rather
than hardcoded, so it is asserted in both directions — a page that states the
registration policy from a constant becomes a stale promise the day the policy
changes.

-}

import Expect
import Html.Attributes as Attr
import Page.Faq as Faq
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector


inviteOnly : Query.Single msg
inviteOnly =
    Faq.view { inviteOnly = True } |> Query.fromHtml


registrationOpen : Query.Single msg
registrationOpen =
    Faq.view { inviteOnly = False } |> Query.fromHtml


{-| The page's public contract. Order follows the reading order of the page.
-}
publishedQuestionIds : List String
publishedQuestionIds =
    [ "what-is-this"
    , "who-runs-it"
    , "isbn-gate"
    , "manual-isbn"
    , "duplicate-editions"
    , "five-shelves"
    , "what-we-store"
    , "data-export"
    , "erasure"
    , "photo-retention"
    , "who-sees-my-shelves"
    , "what-leaves-the-platform"
    , "business-listings"
    , "open-source"
    , "licence"
    , "self-hosting"
    , "closed-beta"
    , "invitations"
    , "running-costs"
    , "how-its-funded"
    ]


sectionTitles : List String
sectionTitles =
    [ "What this is"
    , "Adding books"
    , "Your data"
    , "The code"
    , "The closed beta"
    , "What it costs"
    ]


testIdSelector : String -> Selector.Selector
testIdSelector value =
    Selector.attribute (Attr.attribute "data-testid" value)


suite : Test
suite =
    describe "Page.Faq"
        [ describe "structure"
            [ test "renders the six sections by title" <|
                \() ->
                    inviteOnly
                        |> Expect.all
                            (List.map (\title -> Query.has [ Selector.text title ]) sectionTitles)
            , test "the section-jump row carries one jump per section" <|
                \() ->
                    inviteOnly
                        |> Query.find [ testIdSelector "faq-jumps" ]
                        |> Query.findAll [ Selector.class "faq__jump" ]
                        |> Query.count (Expect.equal (List.length sectionTitles))
            , test "every published question id renders as its own accordion" <|
                \() ->
                    inviteOnly
                        |> Expect.all
                            (List.map
                                (\id ->
                                    Query.find [ testIdSelector ("faq-question-" ++ id) ]
                                        >> Query.has [ Selector.attribute (Attr.id id) ]
                                )
                                publishedQuestionIds
                            )
            , test "publishes exactly the contracted question set — no more, no fewer" <|
                \() ->
                    inviteOnly
                        |> Query.findAll [ Selector.class "faq__question" ]
                        |> Query.count (Expect.equal (List.length publishedQuestionIds))
            , test "each accordion carries a summary the reader can operate" <|
                \() ->
                    inviteOnly
                        |> Query.findAll [ Selector.class "faq__question-summary" ]
                        |> Query.count (Expect.equal (List.length publishedQuestionIds))
            ]
        , describe "answers are open on arrival"
            [ test "every question ships with the open attribute, so browser find works" <|
                \() ->
                    inviteOnly
                        |> Query.findAll
                            [ Selector.class "faq__question"
                            , Selector.attribute (Attr.attribute "open" "")
                            ]
                        |> Query.count (Expect.equal (List.length publishedQuestionIds))
            ]
        , describe "the answers that must match the implementation"
            [ test "the ISBN-gate answer names both catalogues and points at manual entry" <|
                \() ->
                    inviteOnly
                        |> Query.find [ testIdSelector "faq-question-isbn-gate" ]
                        |> Expect.all
                            [ Query.has [ Selector.text "Open Library or Google Books" ]
                            , Query.find [ Selector.attribute (Attr.href "/upload") ]
                                >> Query.has [ Selector.text "type the ISBN in by hand" ]
                            ]
            , test "the erasure answer links the control that performs it" <|
                \() ->
                    inviteOnly
                        |> Query.find [ testIdSelector "faq-question-erasure" ]
                        |> Query.has [ Selector.attribute (Attr.href "/settings/privacy") ]
            , test "the erasure answer is honest that comments survive as stripped shells" <|
                \() ->
                    inviteOnly
                        |> Query.find [ testIdSelector "faq-question-erasure" ]
                        |> Query.has
                            [ Selector.text "stripped of their text and detached from you" ]
            , test "the export answer links the control that performs it" <|
                \() ->
                    inviteOnly
                        |> Query.find [ testIdSelector "faq-question-data-export" ]
                        |> Query.has [ Selector.attribute (Attr.href "/settings/privacy") ]
            , test "the outbound-services answer links the transparency essay" <|
                \() ->
                    inviteOnly
                        |> Query.find [ testIdSelector "faq-question-what-leaves-the-platform" ]
                        |> Query.has [ Selector.attribute (Attr.href "/transparency") ]
            , test "photo retention states the thirty-day ceiling" <|
                \() ->
                    inviteOnly
                        |> Query.find [ testIdSelector "faq-question-photo-retention" ]
                        |> Query.has [ Selector.text "Thirty days at the outside" ]
            , test "the business-listing answer links the removal form itself" <|
                \() ->
                    -- The reason this question exists: the form was reachable
                    -- only by typed URL, so an answer that described it without
                    -- linking it would leave the gap exactly where it was.
                    inviteOnly
                        |> Query.find [ testIdSelector "faq-question-business-listings" ]
                        |> Query.has [ Selector.attribute (Attr.href "/listing-removal") ]
            , test "the business-listing answer names both outcomes, not just the fast one" <|
                \() ->
                    inviteOnly
                        |> Query.find [ testIdSelector "faq-question-business-listings" ]
                        |> Expect.all
                            [ Query.has [ Selector.text "the listing comes down immediately" ]
                            , Query.has [ Selector.text "the listing is still visible" ]
                            ]
            ]
        , describe "the licence answers match the tracked LICENSE"
            [ test "the open-source answer says source available, not open source" <|
                \() ->
                    inviteOnly
                        |> Query.find [ testIdSelector "faq-question-open-source" ]
                        |> Expect.all
                            [ Query.has [ Selector.text "source available" ]
                            , Query.has [ Selector.text "It is not licensed for you to run, copy, or modify." ]
                            ]
            , test "the licence answer links the tracked LICENSE file itself" <|
                \() ->
                    inviteOnly
                        |> Query.find [ testIdSelector "faq-question-licence" ]
                        |> Query.has
                            [ Selector.attribute
                                (Attr.href "https://github.com/erinversfeldcodes/thestacks/blob/main/LICENSE")
                            ]
            , test "self-hosting is answered 'not today', not quietly dropped" <|
                \() ->
                    inviteOnly
                        |> Query.find [ testIdSelector "faq-question-self-hosting" ]
                        |> Query.has [ Selector.text "Not today" ]
            ]
        , describe "the closed-beta answer follows the server flag"
            [ test "invite-only says so" <|
                \() ->
                    inviteOnly
                        |> Query.find [ testIdSelector "faq-question-closed-beta" ]
                        |> Query.has
                            [ Selector.text "new accounts are opened by invitation at the moment" ]
            , test "open registration says so instead, and links the sign-up page" <|
                \() ->
                    registrationOpen
                        |> Query.find [ testIdSelector "faq-question-closed-beta" ]
                        |> Expect.all
                            [ Query.has [ Selector.text "registration is open" ]
                            , Query.has [ Selector.attribute (Attr.href "/login") ]
                            ]
            , test "the two renderings genuinely differ — the answer is not a constant" <|
                \() ->
                    -- Anchored on the sign-up link rather than on prose: an href
                    -- either resolves or it does not, so this cannot pass because
                    -- a sentence was reworded.
                    inviteOnly
                        |> Query.find [ testIdSelector "faq-question-closed-beta" ]
                        |> Query.hasNot [ Selector.attribute (Attr.href "/login") ]
            ]
        ]
