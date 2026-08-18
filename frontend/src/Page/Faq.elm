module Page.Faq exposing (view)

{-| The public FAQ (`/faq`) — About's reference companion.

About is the invitation; this is the answer sheet. It must not restate About's
copy, and it must not hedge: every answer here is checkable against something,
and where there is a control that does the thing being described, the answer
links to it.

⚠️ **Question ids are the page's public contract.** Once published, an id is
kept even when the wording around it changes, so an external citation of
`/faq#erasure` keeps resolving. Retire a question by answering it with a
pointer, never by dropping its id.

⚠️ **The "Your data" answers describe what the code does, not what we mean.**
A change to the export payload, the deletion steps, the image-retention window,
or the set of outbound services makes an answer here false — which is a
compliance defect wearing the costume of a copy edit.

Every answer renders open. Collapsing is available per question through a
native `<details>`, which is keyboard-operable and needs no JavaScript, but it
is never the default: a collapsed answer cannot be found by the browser's own
search, and that is how a page like this is actually read.

-}

import Html exposing (Html, a, details, div, h1, h2, li, p, section, strong, summary, text, ul)
import Html.Attributes exposing (attribute, class, href, id, rel, target)
import Navigation.Route as Route exposing (Route(..))
import Util.TestId exposing (testId)


type alias Question msg =
    { id : String
    , question : String
    , answer : List (Html msg)
    }


type alias Section msg =
    { id : String
    , title : String
    , questions : List (Question msg)
    }


repositoryUrl : String
repositoryUrl =
    "https://github.com/erinversfeldcodes/thestacks"


licenceUrl : String
licenceUrl =
    repositoryUrl ++ "/blob/main/LICENSE"


view : { inviteOnly : Bool } -> Html msg
view flags =
    let
        content =
            sections flags
    in
    div [ class "page page--faq curator-desk", testId "faq-page" ]
        (viewHeader
            ++ (viewJumps content :: List.map viewSection content)
            ++ [ viewClosing ]
        )


viewHeader : List (Html msg)
viewHeader =
    [ h1 [ class "page__title faq__title" ] [ text "Questions, answered" ]
    , p [ class "faq__lede" ]
        [ text "Plainly, and with links to the thing itself wherever there is one." ]
    ]


{-| The section-jump row. A real `nav` so a screen reader can skip the whole
row, and plain fragment links so they work the way a reader expects.
-}
viewJumps : List (Section msg) -> Html msg
viewJumps content =
    Html.nav
        [ class "faq__jumps"
        , attribute "aria-label" "Sections"
        , testId "faq-jumps"
        ]
        (List.map viewJump content)


viewJump : Section msg -> Html msg
viewJump s =
    a [ class "faq__jump", href ("#" ++ s.id) ] [ text s.title ]


viewSection : Section msg -> Html msg
viewSection s =
    section [ class "faq__section", id s.id ]
        (h2 [ class "faq__section-title" ] [ text s.title ]
            :: List.map viewQuestion s.questions
        )


{-| One question. The `open` attribute ships the answer expanded; the browser
removes it when the reader collapses the question, and nothing in this page
re-renders to put it back.
-}
viewQuestion : Question msg -> Html msg
viewQuestion q =
    details
        [ class "faq__question"
        , id q.id
        , attribute "open" ""
        , testId ("faq-question-" ++ q.id)
        ]
        (summary [ class "faq__question-summary" ] [ text q.question ]
            :: q.answer
        )


viewClosing : Html msg
viewClosing =
    p [ class "faq__closing" ]
        [ text "Still stuck? If you have an account, "
        , link Feedback "tell us — we read everything"
        , text ". Everything the platform measures about itself is on "
        , link Metrics "what we measure"
        , text ", and the reasoning behind publishing any of it is "
        , link DataTransparency "set out at length here"
        , text "."
        ]


{-| An internal link, routed rather than hand-written, so a path change is a
compile error rather than a dead link on the page that promised to be checkable.
-}
link : Route -> String -> Html msg
link route label =
    a [ class "faq__answer-link", href (Route.toPath route) ] [ text label ]


external : String -> String -> Html msg
external url label =
    a
        [ class "faq__answer-link"
        , href url
        , target "_blank"
        , rel "noopener noreferrer"
        ]
        [ text label ]


answer : List (Html msg) -> Html msg
answer =
    p [ class "faq__answer" ]



-- CONTENT
--
-- One function per section, so a copy edit is a local change to one block
-- rather than a re-layout.


sections : { inviteOnly : Bool } -> List (Section msg)
sections flags =
    [ whatThisIs
    , addingBooks
    , yourData
    , theCode
    , closedBeta flags.inviteOnly
    , whatItCosts
    ]


whatThisIs : Section msg
whatThisIs =
    { id = "what-this-is"
    , title = "What this is"
    , questions =
        [ { id = "what-is-this"
          , question = "What is The Stacks?"
          , answer =
                [ answer
                    [ text "A home for your library — the books you have read and the ones you own but haven't got to yet. The unread ones get a shelf of their own rather than a guilty pile, because the portion of a library you haven't read is the interesting part: it is a record of what you still intend to know."
                    ]
                , answer
                    [ text "There are no ads, nothing is sold about you, and no algorithm decides what you should want next. The longer version, with the conviction behind it, is on "
                    , link About "the About page"
                    , text "."
                    ]
                ]
          }
        , { id = "who-runs-it"
          , question = "Who runs it?"
          , answer =
                [ answer
                    [ text "One person, privately, out of their own pocket. There is no company behind it, no investors, and no advertising. That is worth knowing before you trust it with your library: it means the platform has no commercial reason to want your data, and also that support is one person's inbox rather than a department."
                    ]
                ]
          }
        ]
    }


addingBooks : Section msg
addingBooks =
    { id = "adding-books"
    , title = "Adding books"
    , questions =
        [ { id = "isbn-gate"
          , question = "Why was my book refused?"
          , answer =
                [ answer
                    [ text "Because we could not find its ISBN in Open Library or Google Books, and we will not add a book we cannot identify. This is deliberate and it is not a bug: a library full of half-identified guesses is worse than a smaller one that is right."
                    ]
                , answer
                    [ text "If the book is real and the catalogues simply do not have it, "
                    , link Upload "type the ISBN in by hand"
                    , text " — that path skips the photo, not the check."
                    ]
                , answer
                    [ text "There is one narrow exception, and you will notice it when it happens. If the barcode on the cover scans cleanly and its checksum is valid, the book is allowed onto your shelf straight away, titled with its own ISBN until a catalogue lookup fills in the rest. A book showing a number where its title should be is waiting for that, not broken."
                    ]
                , answer
                    [ text "A refusal that says the cataloguing desk is closed is a different thing entirely: that means our lookup service is not answering, there is nothing wrong with your photo, and trying again later will work."
                    ]
                ]
          }
        , { id = "manual-isbn"
          , question = "Can I type an ISBN in myself?"
          , answer =
                [ answer
                    [ text "Yes. "
                    , link Upload "The add-a-book page"
                    , text " offers manual entry from the start, and again on every failure. It goes through exactly the same catalogue check the photo does — what you are skipping is the camera, not the verification, so an ISBN the catalogues do not know will still be refused."
                    ]
                ]
          }
        , { id = "duplicate-editions"
          , question = "I own two copies with different ISBNs. Is that two books?"
          , answer =
                [ answer
                    [ text "It is one book with two editions. The Stacks keeps the two apart on purpose: the "
                    , strong [] [ text "work" ]
                    , text " is the thing you read, and the "
                    , strong [] [ text "edition" ]
                    , text " is the particular printing, with its own ISBN and format. Your shelf holds the edition you actually own, so a hardback and its paperback reissue can sit there as the distinct objects they are without your library claiming you have read the same book twice."
                    ]
                ]
          }
        , { id = "five-shelves"
          , question = "What are the five shelves?"
          , answer =
                [ answer [ text "Every book you add finds a home on one of five:" ]
                , ul [ class "faq__list" ]
                    [ li [ class "faq__list-item" ]
                        [ strong [] [ text "Antilibrary" ], text " — owned, unread. The promise." ]
                    , li [ class "faq__list-item" ]
                        [ strong [] [ text "Library" ], text " — read, and kept." ]
                    , li [ class "faq__list-item" ]
                        [ strong [] [ text "Reading pile" ], text " — what you are in the middle of right now." ]
                    , li [ class "faq__list-item" ]
                        [ strong [] [ text "Wishlist" ], text " — not yet yours, but wanted." ]
                    , li [ class "faq__list-item" ]
                        [ strong [] [ text "Looking for a home" ], text " — read, and ready to pass on." ]
                    ]
                , answer [ text "Move a book between them as your relationship with it changes; the move is recorded so the shelves have a history rather than only a present tense." ]
                ]
          }
        ]
    }


yourData : Section msg
yourData =
    { id = "your-data"
    , title = "Your data"
    , questions =
        [ { id = "what-we-store"
          , question = "What do you store about me?"
          , answer =
                [ answer
                    [ text "Your account — email address, display name, handle, and the settings you have chosen. Your bookshelves and the books on them, along with the record of moving a book from one shelf to another. Anything you have written: posts, and comments on them. And, briefly, the photos you upload while a book is being identified."
                    ]
                , answer
                    [ text "The significant actions taken on your account are written to a log only you can read, at "
                    , link SettingsAuditLog "your audit log"
                    , text "."
                    ]
                ]
          }
        , { id = "data-export"
          , question = "What is in a data export?"
          , answer =
                [ answer
                    [ text "You can ask for one from "
                    , link SettingsPrivacy "your privacy settings"
                    , text ". It gathers your account record, your bookshelves, every placement and the history behind it, the record of each uploaded image (when it arrived and what became of it — not the image itself), your posts and comments, invitations, library imports, and your writing-assistant sessions."
                    ]
                , answer
                    [ text "It deliberately leaves out the things that are not yours to carry away: your password hash, your confirmation and password-reset tokens, the counters behind lockout after failed logins, and the raw vectors behind search. Those are machinery, not your reading."
                    ]
                ]
          }
        , { id = "erasure"
          , question = "What actually happens when I delete my account?"
          , answer =
                [ answer
                    [ text "It happens at once, in a single transaction, and there is no grace period and no undo. Your shelves, your placements and their history, your imports, your posts, the people you follow and have blocked, your group memberships, your marketplace listings and offers, your uploaded images — both the files in storage and the records of them — and your account itself are deleted outright. Every session is destroyed; if even one survived, the whole erasure is rolled back rather than left half-done."
                    ]
                , answer
                    [ text "Two things are handled differently, and it is more honest to name them than to let you assume otherwise. Comments you have written are stripped of their text and detached from you, and the empty shell of the comment stays, so replies hanging off it do not vanish along with their parent. And entries in the platform's event log are not removed — the log is append-only by design — but every entry about you has its contents emptied out."
                    ]
                , answer
                    [ text "The control is in "
                    , link SettingsPrivacy "your privacy settings"
                    , text ", and it asks you to type the word out before it will do anything."
                    ]
                ]
          }
        , { id = "photo-retention"
          , question = "How long do you keep the photos I upload?"
          , answer =
                [ answer
                    [ text "Thirty days at the outside, and in practice minutes. A photo is deleted as soon as the book in it has been identified; anything left behind is swept nightly, and a photo that never got as far as identification is cleared within two hours. Nothing is kept in case it turns out to be useful later."
                    ]
                ]
          }
        , { id = "who-sees-my-shelves"
          , question = "Who can see my shelves?"
          , answer =
                [ answer
                    [ text "Whoever you decide, and by default nobody. Your profile visibility — only you, signed-in readers, or anyone — sets a ceiling, and each shelf can be more private than that ceiling but never more public, so you cannot expose a shelf by forgetting a setting somewhere else."
                    ]
                , answer
                    [ text "Your profile and your books do not appear in search-engine results. Both controls live in "
                    , link SettingsPrivacy "your privacy settings"
                    , text "."
                    ]
                ]
          }
        , { id = "what-leaves-the-platform"
          , question = "What leaves the platform, and to whom?"
          , answer =
                [ answer [ text "Named, so you can check rather than take our word for it:" ]
                , ul [ class "faq__list" ]
                    [ li [ class "faq__list-item" ]
                        [ strong [] [ text "Open Library and Google Books" ]
                        , text " — an ISBN or a title, to identify a book. Nothing about your account goes with it."
                        ]
                    , li [ class "faq__list-item" ]
                        [ strong [] [ text "Modal" ]
                        , text " — the photo you upload, so a model can read the cover. The photo, and nothing else about you."
                        ]
                    , li [ class "faq__list-item" ]
                        [ strong [] [ text "Cloudflare R2" ]
                        , text " — where an uploaded image is stored for the short time it is kept."
                        ]
                    , li [ class "faq__list-item" ]
                        [ strong [] [ text "Resend" ]
                        , text " — your email address and display name, to send you account email."
                        ]
                    , li [ class "faq__list-item" ]
                        [ strong [] [ text "Together AI" ]
                        , text " — the text of a post you publish, to work out which books it is about."
                        ]
                    ]
                , answer
                    [ text "There is no advertising network, no third-party analytics, and no payment processor connected to the platform at all — not disabled, not configured and unused: absent. What the platform measures about itself is published at "
                    , link Metrics "what we measure"
                    , text ", and the argument for publishing it is "
                    , link DataTransparency "here"
                    , text "."
                    ]
                ]
          }
        ]
    }


theCode : Section msg
theCode =
    { id = "the-code"
    , title = "The code"
    , questions =
        [ { id = "open-source"
          , question = "Is The Stacks open source?"
          , answer =
                [ answer
                    [ text "Not in the strict sense, and it would be easy to imply otherwise. The source is public — you can read every line of it, which is what makes the rest of this page checkable rather than a set of promises. It is not licensed for you to run, copy, or modify. The accurate phrase is "
                    , strong [] [ text "source available" ]
                    , text "."
                    ]
                , answer
                    [ text "The code is at "
                    , external repositoryUrl "github.com/erinversfeldcodes/thestacks"
                    , text "."
                    ]
                ]
          }
        , { id = "licence"
          , question = "What does the licence actually allow?"
          , answer =
                [ answer
                    [ text "Reading. The licence at the root of the repository reserves copyright and publishes the source for reference and learning; running it, copying it, modifying it, redistributing it, or using it to train a model all require written permission first. Do not take that summary on trust — "
                    , external licenceUrl "read the licence"
                    , text ", it is one page."
                    ]
                , answer
                    [ text "If you want to do something the licence does not cover, it tells you to open an issue and ask, and asking is genuinely the intended route rather than a formality." ]
                ]
          }
        , { id = "self-hosting"
          , question = "Can I self-host it?"
          , answer =
                [ answer
                    [ text "Not today, and the reason is the licence rather than the software. The platform is built to be self-hosted — that is a design property, and everything needed to do it is in the repository — but the licence does not currently grant you the right to run it. That is a decision that could change; it has not yet."
                    ]
                ]
          }
        ]
    }


{-| The section id is `beta`, not `closed-beta`: `closed-beta` is spoken for by
the question below it, and two elements answering to one fragment is a deep
link that lands wherever the browser feels like.
-}
closedBeta : Bool -> Section msg
closedBeta inviteOnly =
    { id = "beta"
    , title = "The closed beta"
    , questions =
        [ { id = "closed-beta"
          , question = "Can I sign up?"
          , answer =
                if inviteOnly then
                    [ answer
                        [ text "Not yet — new accounts are opened by invitation at the moment. The Stacks is deliberately small while it is still being built, because a platform whose owner can read every piece of feedback is a platform that gets fixed."
                        ]
                    ]

                else
                    [ answer
                        [ text "Yes — registration is open. You can "
                        , link Login "make an account"
                        , text " now."
                        ]
                    ]
          }
        , { id = "invitations"
          , question = "How do I get an invitation?"
          , answer =
                [ answer
                    [ text "At the moment, you don't — invitations are extended personally by the owner, and there is no process for requesting one. That isn't a velvet rope; it is the honest size of the platform right now. If that changes, this answer will too."
                    ]
                ]
          }
        ]
    }


whatItCosts : Section msg
whatItCosts =
    { id = "what-it-costs"
    , title = "What it costs"
    , questions =
        [ { id = "running-costs"
          , question = "What does it cost to run?"
          , answer =
                [ answer
                    [ text "Published to the cent, and worked out from the actual bills rather than an estimate, at "
                    , link CostTransparency "what it costs to run The Stacks"
                    , text ". Every third-party service the platform pays for is accounted for there."
                    ]
                ]
          }
        , { id = "how-its-funded"
          , question = "If I am not paying, how is it funded?"
          , answer =
                [ answer
                    [ text "Out of one person's pocket. That is the entire funding model, and it is the reason the answers above can be as short as they are: with nothing to sell, there is no arrangement about your reading that has to be explained carefully. The cost of keeping it that way is published alongside everything else."
                    ]
                ]
          }
        ]
    }
