module Page.DataTransparency exposing (view)

{-| The long-form data-transparency essay, linked from the /metrics
subtitle ("this piece"). Owner-authored copy, edited in place like
Page.About, whose `about__*` classes it reuses on purpose: same
long-form-prose styling, no new class family to keep in sync.
-}

import Html exposing (Html, a, div, h1, h2, p, section, text)
import Html.Attributes exposing (class, href, rel, target)
import Util.TestId exposing (testId)


view : Html msg
view =
    div [ class "page page--about curator-desk", testId "data-transparency-page" ]
        [ h1 [ class "page__title about__title" ] [ text "What we agreed to, and what we didn't" ]
        , p [ class "about__lede" ]
            [ text "Everything this platform measures (about itself and about you) is made visible to you, whether on your personal metrics page or the public-facing metrics. This is a piece musing on my philosophy and why I've taken this approach with The Stacks." ]
        , viewHowWeGotHere
        , viewNotAConspiracy
        , viewNotNecessary
        , viewHowThisWorks
        , viewNeverFree
        , viewClosing
        ]


viewHowWeGotHere : Html msg
viewHowWeGotHere =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ] [ text "Welcome to the Internet: where we came from and how we got here" ]
        , p [ class "about__section-prose" ]
            [ text "Once upon a time, many years ago when we were but young Internet-lings, we clicked accept on MySpace and Facebook Ts and Cs, on whatever came bundled with the browser on an enormous beige tower, we were reasoning by analogy. We had signed things before (or our parents had). You had signed a page when you bought a car agreeing the dealer wasn't liable for your poor driving ability when you wrapped it around a lamp post in the first week. You signed something at work letting them put your photograph in the company propaganda post. Terms and conditions were a genre we thought we understood: long, one-sided, mostly harmless. And for the most part they still are, though increasingly less so in the digital sphere (have you heard of Disney Plus including a waiver in the streaming service terms absolving them of responsibility if you die at one of their parks? Diabolical)." ]
        , p [ class "about__section-prose" ]
            [ text "Things changed slowly: a clause at a time, as more of our lives moved into the machines. We felt we were keeping up with the changes with things like GDPR covering user protections in the EU, but this just introduced predatory practices where it was easier (and in some cases only possible) to enforce one's privacy on a smart phone, but feature phone users (still popular in African countries) had their privacy treated as optional. New technology arrived that most people had no way of knowing about, and nobody with an incentive to explain it did: what it collected, what it was for, what it might one day become." ]
        , p [ class "about__section-prose" ]
            [ text "In fairness, that last part is genuinely hard. Predicting the future is a thankless job. Rehearsing the worst case has real uses — premeditatio malorum is an excellent practice to explore — but dooms-proclaiming a-la-If-Anyone-Builds-It-Everyone-Dies is not helpful." ]
        ]


viewNotAConspiracy : Html msg
viewNotAConspiracy =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ] [ text "No, there isn't a grand unified plot against us (or you specifically)" ]
        , p [ class "about__section-prose" ]
            [ text "Sadly, conspiracy theories hinge on two critical components: common goal and an ability to keep one's mouth shut. The larger and more complicated it becomes to deliver the conspiracy, the harder it is to keep it a conspiracy, and "
            , a
                [ class "about__prose-link"
                , href "https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0147905"
                , target "_blank"
                , rel "noopener noreferrer"
                , testId "transparency-conspiracy-model-link"
                ]
                [ text "we can model this" ]
            , text ". We got here through a long series of small, disconnected decisions, made by people who had power and people who were acquiring it, none of whom lifted their head long enough to really take in and appreciate the lush environment they were landmining. By the time the next generation was running through the grass, the mines were everywhere, and everything cascaded into a hellscape. It's tempting to blame capitalism or communism or Obama or Putin or the techno-garchs or anyone, really, but the fact of the matter is things are broken too broadly for it to be an organised effort."
            ]
        , p [ class "about__section-prose" ]
            [ text "Regardless, here we are, living with the consequences. This wave of AI is built substantially on work taken from artists who were never asked, privacy violations of millions of people worldwide, and the companies that took it are congratulated for their boldness. "
            , a
                [ class "about__prose-link"
                , href "https://en.wikipedia.org/wiki/Aaron_Swartz"
                , target "_blank"
                , rel "noopener noreferrer"
                , testId "transparency-swartz-link"
                ]
                [ text "Aaron Swartz" ]
            , text " faced thirteen federal felony counts for bulk-downloading academic papers he had legitimate access to, and died by suicide at twenty-six because the U.S. government was relentlessly pursuing him for... what exactly? Wanting to make scientific knowledge public? J.K. Rowling gets special protections for Harry Potter IP and an "
            , a
                [ class "about__prose-link"
                , href "https://www.theguardian.com/technology/2026/jul/22/bloomsbury-book-publisher-anthropic-copyright-settlement"
                , target "_blank"
                , rel "noopener noreferrer"
                , testId "transparency-settlement-link"
                ]
                [ text "out of court settlement" ]
            , text " for AI labs \"accidentally\" including the books in their training corpus, forcing them to remove them and retrain the models, but the authors on WattPad or who self-published on Amazon don't get afforded the same treatment."
            ]
        ]


viewNotNecessary : Html msg
viewNotNecessary =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ]
            [ text "Lessons from "
            , a
                [ class "about__prose-link"
                , href "https://plurality.net/"
                , target "_blank"
                , rel "noopener noreferrer"
                , testId "transparency-plurality-link"
                ]
                [ text "Plurality" ]
            , text " and the community-minded"
            ]
        , p [ class "about__section-prose" ]
            [ text "AI never had to be built this way. The digital world does not have to be shit." ]
        , p [ class "about__section-prose" ]
            [ text "Being a luddite doesn't mean living without machines, and in our age it does not mean rejecting AI or data gathering entirely. The Luddites were not frightened of technology but rather objected to machines being used to break the people who worked them. The scary thing about the current state of AI is that it cannot progress without further data. The Chinese approach of specific-AI is great, and will have many more breakthroughs, but if the American approach of single-super-intelligence-that-will-make-this-bubble-not-a-bubble is to be realised, they're going to need a shit-ton more data soon. In both cases we will, in the long term, need to see ourselves as part of a digital ecosystem if we want them to progress beyond their current bounds. Someone once posed the idea to me of data from humans being a-kin to a blood donation to digital systems, and it's a powerful analogy to sit with. I would offer one refinement to it though, and it's a refinement that drives the data philosophy in The Stacks: the data is always under the control of the human who created it. This has been the standard in academic research for a long time, at least in research conducted with an Ethics Board worth its salt. When a human donates blood, that blood is really a temporary loan to another human: the recipient uses the blood while their body heals and creates enough of its own. The donor can never ask for it back once it's entered a recipient, but they also need never fear the recipient can use it for anything other than what the donation was meant for. Data is different in this regard: we can interrogate it in new ways, feed it into many different systems, and so we need to be able to retain control over it for the consent of its donation to the digital to be true consent. We also know that the quality of data matters more than the volume, and that when we build trust in the way we gather the data and the respect with which we intend to treat it, we can do "
            , a
                [ class "about__prose-link"
                , href "https://blogs.nvidia.com/blog/te-hiku-media-maori-speech-ai/"
                , target "_blank"
                , rel "noopener noreferrer"
                , testId "transparency-te-hiku-link"
                ]
                [ text "incredible things with far less" ]
            , text " than the builders of monstrous data centres would have you believe."
            ]
        ]


viewHowThisWorks : Html msg
viewHowThisWorks =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ] [ text "So here is how this place works" ]
        , p [ class "about__section-prose" ]
            [ text "So. Anything The Stacks measures gets put on a dashboard. If it's something that doesn't identify you it will be on the publicly accessible page, if it's something that can be used in conjunction with other data to identify you, it'll be on a page only visible to you. If it's not something I have to measure in order to comply with GDPR or another regional requirement, it will be something you can opt out of, with no impact on your experience of this platform. I will do my best to explain why things are captured, what use they have now and what use I can see them having in the future (though I confess, I lack a crystal ball)." ]
        , p [ class "about__section-prose" ]
            [ text "Right now, this is a small platform, meant for me and mine. As that community grows, I might find there are more things I'm legally required to keep records of. Sorry up front for any changes, but I'll keep true to transparency and education of both of us while doing this." ]
        , p [ class "about__section-prose" ]
            [ text "Underneath all of this: consent must be real, which means you need to be informed and you need to retain control as far as possible. This might only be controversial in a for-profit context, to be honest, because research studies have struggled with this for... a while! They are routinely thrown into disarray when a participant withdraws consent, sometimes causing the design to collapse and years of work to start again. Ethics boards accept that cost, because the alternative is worse, it is to claim that knowledge could be obtained without community. Knowledge is a collective project, it can only be described and uncovered when there is trust in the ecosystem." ]
        ]


viewNeverFree : Html msg
viewNeverFree =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ] [ text "No such thing as a free lunch" ]
        , p [ class "about__section-prose" ]
            [ text "The other thing published here is money. This is a self-funded hobby at present. Membership will likely stay invitation-only for a long time, and maybe one day this becomes something donation-funded, in the Wikipedia mould." ]
        , p [ class "about__section-prose" ]
            [ text "But, as we all know by now, free to use is never actually free. Someone is paying to keep the lights on. In this case it's me, and the fee is my friends giving me feedback :) If it ever got to a volume I couldn't sustain, someone else is going to have to chip in or folks will need to be pushed out (which seems like a dick-ish move). So the running costs are published too, on "
            , a [ class "about__prose-link", href "/costs", testId "transparency-costs-link" ]
                [ text "the costs page" ]
            , text ": every provider, what we are billed, and what those providers are used for and how your data flows through them. You should know where your data goes and you should know how I'm designing things to streamline costs without sacrificing performance in the long run."
            ]
        , p [ class "about__section-prose" ]
            [ text "Another way I might get funding to keep the lights on would be to sell the data gathered here." ]
        , p [ class "about__section-prose" ]
            [ text "If that ever happens, it will happen because I've been able to design a process and engage with buyers who share in the philosophy here: you will be told what is being sold, to whom, for how much, and what their intended use is. You will be able to retract consent and have your data removed after the sale if you later change your mind. There will be no repercussions for retraction. The true ideal I'm aiming for with this open costing model is to have everyone on the platform also share in any profit from the sale, and to have a say in how the profit gets divided between re-investing in the platform and giving to the community on the platform." ]
        ]


viewClosing : Html msg
viewClosing =
    section [ class "about__transparency" ]
        [ p [ class "about__closing" ]
            [ text "TL;DR: what we're measuring about you is on the metrics page, what it all costs to run and why on the costs page. If anything there doesn't line up, please get in touch via "
            , a
                [ class "about__prose-link"
                , href "https://github.com/erinversfeldcodes/thestacks/discussions"
                , target "_blank"
                , rel "noopener noreferrer"
                , testId "transparency-github-link"
                ]
                [ text "this project's GitHub page" ]
            , text " and let's figure it out together."
            ]
        , a [ class "about__link about__link--metrics", href "/metrics", testId "transparency-metrics-link" ]
            [ text "See what we measure" ]
        , a [ class "about__link about__link--costs", href "/costs", testId "transparency-costs-page-link" ]
            [ text "See what it costs to run" ]
        ]
