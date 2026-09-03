module Page.Architecture exposing (view)

{-| The long-form architecture-and-costs essay, linked from the /metrics costs
widget ("a full discussion of why all of these expenses are incurred").
-}

import Html exposing (Html, a, div, h1, h2, li, p, section, strong, text, ul)
import Html.Attributes exposing (class, href, rel, target)
import Util.TestId exposing (testId)


view : Html msg
view =
    div [ class "page page--about curator-desk", testId "architecture-page" ]
        [ h1 [ class "page__title about__title" ] [ text "No such thing as a free lunch" ]
        , p [ class "about__lede" ]
            [ text "Many moons ago, when I was still in high school, it felt like a momentous thing to get an email address. I remember sitting with my sister at the dining room table and trying to thing of a cool username that could become part of the email address. I thought hers was so cool and edgy, I wanted something like that of my own. Being neither so cool nor so edgy, after much agonising I came up with something stupid and it follows me around the internet to this day. I remember it with equal parts affection (for my sister's patience) and frustration at my lack of awarenes. It seemed so cool to be able to get an email address for free! Google was so incredible for making GMail available like that! The young ones around here may not believe me, but getting an email account was considered a bonus when you signed up with your ISP at one point. Utterly wild to think of now. Looking back, the fact that something that we usually paid for (implicitly, though our ISP) was being offered for free (Gmail, Hotmail, Yahoo...) was a smell. Something was being taken from us, and today we can safely look back and we can say it was 'everything about us on the Internet'. It took me a long time to understand why my then-boyfriend was so suspicious of Facebook. Why he had an account but didn't use it and post to it as much as I did. It took becoming a software engineer, building these systems, running them, becoming intimately familiar with their costs, to really understand why 'selling my data' in exchange for a free email, social media account etc, was a really bad exchange. The"
            , a [ class "about__prose-link", href "/metrics", testId "architecture-metrics-link" ]
                [ text "costs page" ]
            , text " makes visible to you what the cost of running a platform like this is, at least at this scale. I should emphasise, scale is an important costing factor in software. The bigger it is, the cheaper the unit costs are (a bit of broken maths that, when taken to the logic extreme, is the same line of reason used to justify statements like '"
            , a
                [ class "about__prose-link"
                , href "https://www.businessinsider.com/amazon-ceo-jeff-bezos-liquidates-billions-to-fund-blue-origin-2018-4"
                , target "_blank"
                , rel "noopener noreferrer"
                , testId "architecture-bezos-link"
                ]
                [ text "the most effective means of deploying my capital is invest in space travel" ]
            , text "', but I digress). I feel its important to share the reasoning behind these costs, because if this thing ever turns into a data selling machine, you should know why. So please indulge me in explaining the architecture behind The Stacks, why I've chosen certain paid solutions and how I'm trying to keep them cost effective. I won't only cover the stuff that's being paid for, I'll try and cover everything and keep this essay up to date as things change so that you can keep learning and understanding, and hopefully taking some of this and questioning things around you."
            ]
        , viewShapeOfTheBill
        , viewInference
        , viewHostingAndDatabase
        , viewBoughtNotBuilt
        , viewInvisibleDecisions
        , viewSelfHosting
        , viewClosing
        ]



-- 1. WHAT THE BILL LOOKS LIKE


viewShapeOfTheBill : Html msg
viewShapeOfTheBill =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ] [ text "The shape of the bill" ]
        , p [ class "about__section-prose" ]
            [ text "I'm going to start by explaining the cost breakdown, at least in principle. I've tried to build this with live data, sadly few platforms offer that for their billing data, at least on the freemium tiers that I tend to use :) (To any *aaS services reading this: hey, please make billing data readily available via an API the norm.) As it stands, the majority of the cost data advertise is estimates based on the usage I'm measuring internally and what I've hardcoded about the pricing models of these services. One day I might do something fancy where I can upload the monthly invoices and retro-actively give much more accurate measures, but I know myself and right now that's not something I want to build or manage here. So on with the details!"
            , text " Hosting (running the services which make up The Stacks on a computer that isn't my laptop), the database (where everything is stored) and the domain (the purchase of the shiny URL) cost roughly the same whether a few dozen or a few hundred people are using this site. As usage scales the hardware required to run will need to get beefier (more memory, more storage), but the running costs associated with it will come down sharply (more people to divide the beef between). Conversely, actions like identifying a book from a photograph will always be expensive, though for more established users we'd expect to see less of that happening (if you've listed your entire library, do you need to add hundreds of new books each day?), while for new users there would be a high cost associated (they've still got to get their whole library in here). The combination of these fixed and variable costs, and how they shift and change depending on the user base, is worth meditating on the next time you use an app that tells you its free. Not even your phone's operating system is a free lunch, really. Someone, somewhere, is paying in some form, and we should press to be sure they're not collecting payment from us when they tell us its free."
            ]
        , p [ class "about__section-prose" ]
            [ text "Not everything that is free is poisoned fruit: Plurality is a great book exploring digital systems of participation that don't extract payment from their users, but all of those systems build off of explicit consent from the users. Robin Wall-Kimmerer's Braiding Sweetgrass is a slow meditation on what it means to  What has instead largely happened in the case of apps and everyday software is what "
            ]
        , p [ class "about__section-prose" ]
            [ text "(Owner: the argument about what that curve does to incentives goes here — the pressure to grow, and what a platform starts doing to its users when the fixed costs are large and the per-head revenue is zero.)" ]
        ]



-- 2. INFERENCE


viewInference : Html msg
viewInference =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ] [ text "Inference: the only cost that grows when you use it" ]
        , p [ class "about__section-prose" ]
            [ text "No book enters The Stacks without a verified ISBN. That rule is the foundation everything else rests on, and it is also the reason there is a GPU bill: a photograph of a shelf has to become a set of identified editions, and that is machine-vision work." ]
        , p [ class "about__section-prose" ]
            [ text "So the vision path is built as a "
            , strong [] [ text "cascade" ]
            , text ", cheapest first: read the barcode; failing that, match the cover against an embedding index; failing that, run OCR; and only when all of those have failed, ask a vision-language model. Each rung costs more than the one above it, and most photographs never reach the bottom. The expensive step is the last resort rather than the default — which is a cost decision and an accuracy decision at the same time."
            ]
        , p [ class "about__section-prose" ]
            [ text "The provider split follows from latency, not price. "
            , strong [] [ text "Modal runs the vision model" ]
            , text " because it caches containers between invocations — a cold start of roughly fifteen to thirty seconds, against two to three minutes for a raw GPU allocation elsewhere. Someone is standing there holding a phone. "
            , strong [] [ text "Together AI summarises reviews" ]
            , text " because that is a background job nobody is waiting on, where per-token pricing wins and a slow cold start costs nothing. Same capability, opposite constraints, different vendor ("
            , a
                [ class "about__prose-link"
                , href "https://github.com/erinversfeldcodes/thestacks/blob/main/docs/decisions/001-modal-over-together-ai.md"
                , target "_blank"
                , rel "noopener noreferrer"
                , testId "architecture-adr-001-link"
                ]
                [ text "ADR 001" ]
            , text ")."
            ]
        , p [ class "about__section-prose" ]
            [ text "Two roads not taken. A managed vision API — Claude, GPT-4V — would have been cheaper to build against and is deliberately not used: running the model myself is part of the point of this project, and it keeps the images out of a third party's pipeline. And "
            , strong [] [ text "keep-warm pinging was ruled out as an anti-pattern" ]
            , text ": paying for an idle GPU around the clock to hide a cold start is a cost you cannot see and cannot justify, so the cold start is worn honestly instead."
            ]
        , p [ class "about__section-prose" ]
            [ text "(Owner: worth being blunt here about what the alternative business model would have been — the photographs are the asset, and an ad-funded version of this platform would have kept them.)" ]
        ]



-- 3. HOSTING AND DATABASE


viewHostingAndDatabase : Html msg
viewHostingAndDatabase =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ] [ text "Hosting and the database, and the price of scaling to zero" ]
        , p [ class "about__section-prose" ]
            [ text "The core runs on Fly.io as a small machine in Ashburn, with the Rust scraper and the self-hosted search alongside it. Postgres is Neon — serverless, free below ten gigabytes, and chosen for one feature above all the others: "
            , strong [] [ text "copy-on-write branching." ]
            , text " Every pull request gets its own database branched off production data in seconds, which is what makes a genuine per-PR preview environment affordable. The marginal cost is the preview compute, not the storage."
            ]
        , p [ class "about__section-prose" ]
            [ text "The core machine is also configured to "
            , strong [] [ text "scale to zero" ]
            , text " when nobody is using it. That is the single largest saving on the hosting line, and it has a consequence I did not anticipate, which is the best illustration on this page of why architecture and cost are the same subject."
            ]
        , p [ class "about__section-prose" ]
            [ text "Fly's managed Prometheus scrapes machines directly over the private network, bypassing the proxy that would wake a sleeping one. A scale-to-zero app is therefore never awake when the scraper calls. "
            , strong [] [ text "It never ingested a single metric — not one, since launch" ]
            , text " — and every dashboard was structurally blank while every check reported healthy. Scraping is simply the wrong model for an app that sleeps. The fix was to invert it: the app now "
            , strong [] [ text "pushes" ]
            , text " to a self-hosted VictoriaMetrics, with its own Grafana beside it ("
            , a
                [ class "about__prose-link"
                , href "https://github.com/erinversfeldcodes/thestacks/blob/main/docs/decisions/021-self-hosted-push-metrics-store.md"
                , target "_blank"
                , rel "noopener noreferrer"
                , testId "architecture-adr-021-link"
                ]
                [ text "ADR 021" ]
            , text ")."
            ]
        , p [ class "about__section-prose" ]
            [ text "So there is a line on the costs page for a metrics store that exists because of a decision made to save money somewhere else. That is normal. It is also the kind of thing you only find by looking, which is why the dashboards are public." ]
        ]



-- 4. BOUGHT, NOT BUILT


viewBoughtNotBuilt : Html msg
viewBoughtNotBuilt =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ] [ text "Bought, not built: search, mail and logs" ]
        , p [ class "about__section-prose" ]
            [ text "Three lines on the bill are things that could have been built and deliberately were not. The test each had to pass was not \"could I write this?\" but \"what would owning it cost me every week forever?\"" ]
        , ul [ class "about__do-list" ]
            [ li [ class "about__do-item" ]
                [ strong [] [ text "Brave Search" ]
                , text " — per-query, with a free tier that covers a small platform entirely. It finds the sources the enrichment pipeline reads. The alternative is scraping a search engine that does not want to be scraped, which is a legal and operational problem rather than an engineering one. A self-hosted federated meta-search runs behind it as a fallback."
                ]
            , li [ class "about__do-item" ]
                [ strong [] [ text "Resend" ]
                , text " — transactional mail, free below a few thousand sends a month. Deliverability is the reason: getting mail into inboxes is a full-time reputational discipline that looks from the outside like a weekend of SMTP configuration."
                ]
            , li [ class "about__do-item" ]
                [ strong [] [ text "Axiom" ]
                , text " — log storage and search. Logs are only worth having if you can find things in them at the moment something is wrong."
                ]
            ]
        , p [ class "about__section-prose" ]
            [ text "(Owner: the general principle you want to land here — buy the thing whose failure mode is somebody else's pager, build the thing that is actually your product.)" ]
        ]



-- 5. THE DECISIONS THAT DON'T APPEAR ON A BILL


viewInvisibleDecisions : Html msg
viewInvisibleDecisions =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ] [ text "The decisions you can't see from the costs" ]
        , p [ class "about__section-prose" ]
            [ text "The costs page shows what was bought. It cannot show what was refused, and those choices shape this platform more than the invoices do. A few worth naming." ]
        , p [ class "about__section-prose" ]
            [ strong [] [ text "There is no message broker." ]
            , text " Every significant state change emits an event, and those events are the backbone of the system — but they are rows in a Postgres table with Oban delivering them, not Kafka. A broker would have been another bill, another thing to operate, another thing to be woken up by, and at this size it buys nothing the database cannot do. The event log being an ordinary table is also why the transparency page can exist at all: it is queryable ("
            , a
                [ class "about__prose-link"
                , href "https://github.com/erinversfeldcodes/thestacks/blob/main/docs/decisions/002-oban-over-kafka.md"
                , target "_blank"
                , rel "noopener noreferrer"
                , testId "architecture-adr-002-link"
                ]
                [ text "ADR 002" ]
            , text ")."
            ]
        , p [ class "about__section-prose" ]
            [ strong [] [ text "The frontend is Elm, not React." ]
            , text " This costs nothing and changes the defect profile completely: no null, no undefined, no runtime exceptions in practice, and every network call modelled as one of four explicit states rather than a scattering of loading booleans. It is a smaller talent pool and a slower start, traded for a class of bug that simply does not occur ("
            , a
                [ class "about__prose-link"
                , href "https://github.com/erinversfeldcodes/thestacks/blob/main/docs/decisions/004-elm-over-react.md"
                , target "_blank"
                , rel "noopener noreferrer"
                , testId "architecture-adr-004-link"
                ]
                [ text "ADR 004" ]
            , text ")."
            ]
        , p [ class "about__section-prose" ]
            [ strong [] [ text "Schemas are Protobuf, but the wire is JSON." ]
            , text " Protobuf here is the contract, not the serialisation — one place where the shape of things is written down, from which the database schemas and the client decoders are generated. What it buys is a build that fails when a change would break an existing consumer, rather than a partner finding out in production ("
            , a
                [ class "about__prose-link"
                , href "https://github.com/erinversfeldcodes/thestacks/blob/main/docs/decisions/007-protobuf-as-contract.md"
                , target "_blank"
                , rel "noopener noreferrer"
                , testId "architecture-adr-007-link"
                ]
                [ text "ADR 007" ]
            , text ")."
            ]
        , p [ class "about__section-prose" ]
            [ strong [] [ text "A book and a copy of a book are different things." ]
            , text " The work is one record; each edition — its ISBN, format, cover, page count — is another. It is more machinery than a single books table, and it is what lets your battered paperback and someone else's hardback be the same book without pretending they are the same object ("
            , a
                [ class "about__prose-link"
                , href "https://github.com/erinversfeldcodes/thestacks/blob/main/docs/decisions/003-works-editions-model.md"
                , target "_blank"
                , rel "noopener noreferrer"
                , testId "architecture-adr-003-link"
                ]
                [ text "ADR 003" ]
            , text ")."
            ]
        , p [ class "about__section-prose" ]
            [ strong [] [ text "The transparency itself was a decision." ]
            , text " A public metrics page, public dashboards and this essay are all architecture: they constrain what can be built later, because anything that would be embarrassing to show is now also expensive to build. That constraint is deliberate ("
            , a
                [ class "about__prose-link"
                , href "https://github.com/erinversfeldcodes/thestacks/blob/main/docs/decisions/019-radical-transparency-metrics.md"
                , target "_blank"
                , rel "noopener noreferrer"
                , testId "architecture-adr-019-link"
                ]
                [ text "ADR 019" ]
            , text ")."
            ]
        , p [ class "about__section-prose" ]
            [ text "(Owner: there are twenty-two of these decision records and the ones above are a sample. Worth saying why they are written down at all — that a decision without its reasoning is indistinguishable from an accident six months later.)" ]
        ]



-- 6. RUNNING IT YOURSELF


viewSelfHosting : Html msg
viewSelfHosting =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ] [ text "Running it yourself" ]
        , p [ class "about__section-prose" ]
            [ text "The costs page invites you to self-host, so here is the honest accounting of what that involves. Most of the bill is optional; one part of it is not." ]
        , ul [ class "about__do-list" ]
            [ li [ class "about__do-item" ]
                [ strong [] [ text "Droppable outright" ]
                , text " — the metrics store, the log storage and the domain. Run it on a laptop for one person and none of them earn their keep."
                ]
            , li [ class "about__do-item" ]
                [ strong [] [ text "Substitutable" ]
                , text " — hosting and the database are ordinary Postgres and an ordinary container; nothing depends on Fly or Neon specifically, though you lose per-PR preview branching, which is worth more than it sounds."
                ]
            , li [ class "about__do-item" ]
                [ strong [] [ text "Load-bearing" ]
                , text " — identification. Without a GPU somewhere in the picture, a photograph of a shelf stays a photograph. Typing ISBNs by hand works and is genuinely fine for a personal library."
                ]
            ]
        , p [ class "about__section-prose" ]
            [ text "The source is "
            , a
                [ class "about__prose-link"
                , href "https://github.com/erinversfeldcodes/thestacks"
                , target "_blank"
                , rel "noopener noreferrer"
                , testId "architecture-repo-link"
                ]
                [ text "on GitHub" ]
            , text ", and questions are welcome on "
            , a
                [ class "about__prose-link"
                , href "https://github.com/erinversfeldcodes/thestacks/discussions"
                , target "_blank"
                , rel "noopener noreferrer"
                , testId "architecture-discussions-link"
                ]
                [ text "the discussion board" ]
            , text "."
            ]
        ]



-- 7. CLOSING


viewClosing : Html msg
viewClosing =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ] [ text "What to ask of anyone else" ]
        , p [ class "about__section-prose" ]
            [ text "The reason for publishing any of this is not that the numbers are impressive — they are small, and that is the point. It is that knowing roughly what a platform costs to run is what lets you ask a sharp question of one that will not tell you." ]
        , p [ class "about__section-prose" ]
            [ text "(Owner: the closing argument. The companion piece on "
            , a [ class "about__prose-link", href "/transparency", testId "architecture-transparency-link" ]
                [ text "what we agreed to, and what we didn't" ]
            , text " covers the consent side; this one is the bill. Somewhere here is the line about what it means when a service has no price and no explanation.)"
            ]
        ]
