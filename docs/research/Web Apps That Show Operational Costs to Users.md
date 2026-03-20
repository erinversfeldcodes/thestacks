# Web Apps That Show Operational Costs to Users

## Overview

Genuinely consumer-facing "this is what it costs to run this app" pages are extremely rare — almost no major commercial web apps do this. However, a rich ecosystem of adjacent patterns exists, ranging from the Open Startup movement to nonprofit financial disclosures to privacy-focused SaaS products that explain their cost structure to justify their pricing. Together, these examples map out what an excellent `/cost` page could look like, and why the idea hasn't gone mainstream yet.

***

## The Closest Real Examples

### 1. Let's Encrypt — "What It Costs to Run Let's Encrypt"

This is perhaps the cleanest, most consumer-facing example of the exact pattern you're describing. In 2016, Let's Encrypt published a detailed breakdown of its operating costs directly on its website — not buried in an annual report, but as a public blog post intended for the people who use the service.[^1]

The breakdown was explicit and structured:

| Expense | Annual Cost |
|---|---|
| Staffing (8 FTE + 2 Mozilla/EFF) | $2.06M |
| Hardware/Software (compute, storage, networking, HSMs) | $0.20M |
| Hosting/Auditing (data centers, WebTrust audits, penetration testing) | $0.30M |
| Legal/Administrative | $0.35M |
| **Total** | **$2.91M** |

Crucially, they explained *why* each line item existed — e.g., why staffing is 70% of costs (24/7 operations demands), what "hosting" actually means (two geographically separated secure data centers), and why auditing is mandatory for a CA. The explicit framing was: "We're doing this because we strive to be a transparent organization, we want people to have some context for their contributions to the project, and because it's interesting." This is the gold standard: real numbers, human language, cause-and-effect reasoning.[^1]

### 2. Buffer — buffer.com/open

Buffer pioneered the Open Startup movement and maintains a live public metrics page at `buffer.com/open`. The page shows real-time MAU (191,726), MRR ($1.9M), ARPU ($28.06), ARR ($22.6M), product roadmap status, and customer satisfaction scores. There's even a "What your subscription supports" section — a direct nod to the idea of explaining operational cost to customers.[^2][^3]

Buffer doesn't, however, break down infrastructure line items (AWS, CDN, database). It focuses on business/financial metrics rather than technical cost topology. The *spirit* of the `/cost` page is there; the engineering specificity is not.

### 3. Leave Me Alone — leavemealone.com/open

Leave Me Alone (an email unsubscribe SaaS) publishes an open page with daily and monthly revenue, expenses, signups, and profits. Their page includes how many subscription emails they've processed and explicit expense categories — a close approximation of the "what does it cost to run this thing" breakdown. Their pricing page also explicitly explains *why* the service isn't free: "Some of our competitors offer a similar unsubscription service for free. They are able to do this because they make money by aggregating and selling data generated from your emails." This is cost transparency used as a trust signal and competitive differentiator.[^4][^5]

### 4. Cal.com — cal.com/open

Cal.com describes itself as "The Most Public Private Company" and publishes salary data, core metrics, and a company handbook. Their blog post on being an Open Startup explicitly frames it as a mechanism that makes screwing over customers structurally harder: "Customers see how active the development cycles are and how their precious monthly subscription is being spent." Infrastructure line items aren't published, but the philosophical foundation is identical to what a `/cost` page would need.[^6][^7]

### 5. Wikimedia Foundation

Wikipedia publishes detailed annual financial reports and budget documents publicly. The 2024–2025 budget allocates $92.8M (49.2% of total) to Infrastructure, and internet hosting alone cost $2.38M in 2021. This data is public and findable, but it's not surfaced for ordinary readers — there's no `/cost` page, only formal financial documents buried in foundation governance pages.[^8][^9][^10]

This illustrates the gap between *disclosing* costs (which many nonprofits do) and *designing cost transparency as a user-facing experience* (which almost nobody does).

### 6. Fathom Analytics — usefathom.com/pricing/infrastructure

Fathom has a dedicated `/pricing/infrastructure` page that explains the actual technical architecture powering the service: Lambda for infinite scaling, SQS for request queuing, multi-AZ database redundancy, firewall layers, CDN topology. It doesn't give dollar amounts but explains *what you're paying for* at a systems level — serverless, enterprise-grade database, global entry points. The framing is explicitly about justifying price: "We're transparent about how much we need to charge each customer to build and maintain our software and infrastructure."[^11][^12]

### 7. SourceHut — sr.ht/billing-faq

SourceHut's pricing philosophy page explicitly explains the funding model, why they charge what they do, and their commitment to never pricing anyone out. The billing FAQ explains that they avoid VC because "if you use their services for free, you are not incentivized to serve your needs first — they are beholden to their investors". Cost structure reasoning is surfaced to users as a values statement, not just a pricing table.[^13][^14][^15]

### 8. Open SaaS Cost Sharing — Reddit / Indie Hacker Community

The indie hacker community regularly publishes detailed cost breakdowns for bootstrapped products as a transparency norm. One representative example shows a $6K MRR SaaS with a fully public expense breakdown:[^16]

- Google Cloud (Cloud Run 62%, Cloud SQL 17%, Compute 11%, Storage 10%): $325/mo
- SendGrid: $87/mo
- Sentry: $28/mo
- Total infra: $440/mo

This level of per-service, per-category granularity — including a sub-breakdown of what *within* GCP costs what — is exactly the model a `/cost` page would want to follow. The community norms here are more advanced than anything any major consumer app has shipped.[^16]

***

## Why This Pattern Is Rare

### Commercial Incentives Work Against It

For most consumer apps, cost transparency is a liability. It reveals margins, exposes architecture decisions to competitors, and creates awkward conversations when costs per user are very low (Facebook's cost per MAU in infra is fractions of a cent) or very high (video streaming). There's no pricing pressure from users to justify costs the way a nonprofit donor expects.

### The Open Startup Movement Is Founder-Facing, Not User-Facing

The /open pages at Buffer, Cal.com, Leave Me Alone, and similar companies share metrics aimed at *other founders* — MRR, churn, conversion rates. This is a marketing and community play ("building in public"), not a genuine attempt to help consumers understand what their usage costs. Infrastructure line items are rarely included even here.[^2][^6][^4]

### Nonprofits Disclose Without Designing

Wikimedia, Let's Encrypt, and the Internet Archive all publish financial data in formats optimized for auditors and grant-makers, not users. The data is accurate and public but not designed as a user experience. Nobody at Wikimedia thought "how do we make a regular Wikipedia reader understand what their pageview costs?"[^10][^8][^1]

***

## What an Excellent `/cost` Page Would Look Like

Based on the best elements across all the examples above, a genuinely excellent consumer-facing cost transparency page would combine:

### Layer 1: The Human Number
A single normalized figure that's instantly relatable: "Running this app costs us X per active user per month." This turns an abstract infrastructure bill into something a person can evaluate. Cost-per-user is already a standard internal engineering/FinOps metric; the innovation is publishing it.[^17]

### Layer 2: Category Breakdown (with percentages)
Following the Let's Encrypt and indie hacker models, a table or visual breaking spend into: Compute, Storage, Network/CDN, Third-Party APIs, Security/Auditing, and People (if relevant). Percentages matter more than absolute dollars for most users.[^16][^1]

### Layer 3: What Each Category Actually Means
The Let's Encrypt post is the gold standard here — for each line item, it explains *why* it exists and what it buys. A storage line item should explain: "This is where your photos, messages, and account data live. We use object storage because it's durable and cheap at scale." The Fathom infrastructure page does this for architecture without dollar amounts.[^12][^1]

### Layer 4: Your Share
The most innovative element would be a personalized cost calculator: "You've uploaded X GB of photos. Storing that costs us approximately Y/month." Plausible's pricing is already structured by pageview volume, which implicitly communicates cost-per-unit to users. Making it user-specific and user-facing would be genuinely novel.[^18]

### Layer 5: Trend Over Time
A chart showing cost-per-user over 12–24 months, showing efficiency improvements (or honest increases). This turns a static disclosure into a story about engineering work, and it's the kind of data the open startup movement publishes but rarely connects to user-level cost implications.[^3][^4]

***

## The Opportunity Gap

No major consumer web app — Facebook, Instagram, Spotify, Netflix, Google — has anything resembling a `/cost` page. Among privacy-focused and indie products, the norm of explaining pricing philosophy is well established but rarely reaches the level of infrastructure specificity that would be genuinely illuminating. The Let's Encrypt post remains a decade-old outlier in terms of combining technical specificity, human framing, and genuine user-facing intent.[^5][^6][^2][^1]

The category is essentially empty at the consumer scale. For a new product or a transparency-forward brand, this is a differentiation opportunity, not just an ethical obligation — it builds the kind of structural trust that's very hard to fake and equally hard for competitors to copy.

---

## References

1. [What It Costs to Run Let's Encrypt](https://letsencrypt.org/2016/09/20/what-it-costs-to-run-lets-encrypt) - Let's Encrypt will require about $2.9M USD to operate in 2017. We believe this is an incredible valu...

2. [What does it mean to be an Open Startup?](https://leavemealone.com/blog/what-does-it-mean-to-be-an-open-startup/) - Learn what it means to be an Open Startup, why transparency is key, and how it can drive growth and ...

3. [Open](https://buffer.com/open) - Open metrics. A transparent company since 2010. Since 2013, we've been open with Buffer's finances a...

4. [How we share all of our company stats and metrics publicly](https://leavemealone.com/blog/how-we-share-company-stats-and-metrics-publicly/) - Leave Me Alone tracks metrics like daily and monthly revenue, user signups, subscription emails proc...

5. [Pricing Plans - Choose the Best Option for Email ...](https://leavemealone.com/pricing/) - The 7 day pass gives you full access to Leave Me Alone for 7 days to get your inbox back under contr...

6. [Why being an open startup matters](https://cal.com/blog/open-startup) - The term "Open Startup" is not new, but still fairly niche. There are Open Startups with millions in...

7. [The Most Public Private Company](https://cal.com/open) - Cal.com, Inc. is an Open Startup, which means it operates fully transparent and shares its salaries ...

8. [Wikimedia Foundation Annual Plan/2024-2025/Budget Details ...](https://meta.wikimedia.org/wiki/Wikimedia_Foundation_Annual_Plan/2024-2025/Budget_Details/gu) - Since 2022-2023, our total investment in Infrastructure has grown from $74.7M to $92.8M, representin...

9. [Wikimedia Foundation](https://en.wikipedia.org/wiki/Wikimedia_Foundation) - The Wikimedia Foundation provides the technical and organizational infrastructure to enable members ...

10. [Financials](https://wikimediafoundation.org/who-we-are/annualreport/2021-annual-report/financials/) - Our annual plan and operating budget are developed through open processes, subject to community feed...

11. [Why Fathom Analytics doesn't have a free plan](https://usefathom.com/blog/free-plan-fathom-analytics) - We invest heavily in infrastructure to ensure our software is fast, reliable and redundant.

12. [Infrastructure](https://usefathom.com/pricing/infrastructure) - Google Analytics charges $150,000/year for their product when you reach 10 million monthly pageviews...

13. [sourcehut pricing - the hacker's forge](https://sourcehut.org/pricing) - All users who host projects on SourceHut are expected to pay according to their means. choose the su...

14. [Billing FAQ - man.sr.ht](https://man.sr.ht/billing-faq.md) - SourceHut does not price any users out of the service. If the minimum fees are too high for your fin...

15. [Here is a list of free Git hosting services for open source software](https://news.ycombinator.com/item?id=33236094) - Sourcehut says they may some day charge people to host open source software on their server, but rig...

16. [What does is cost to run a bootstrapped SaaS? ...](https://www.reddit.com/r/SaaS/comments/qqx979/what_does_is_cost_to_run_a_bootstrapped_saas_a/) - What does is cost to run a bootstrapped SaaS? A breakdown of our costs. · Ghost: $29 · Super: $12 · ...

17. [SaaS cost grow—without financial control - USU](https://www.usu.com/saas-cost-grow-without-control) - Cost transparency across the organization; Clear allocation and accountability; Unit-economics think...

18. [Plausible Analytics - Features, Pricing & Alternatives 2026](https://newmetrics.io/analytics-tools/plausible/) - Plausible Analytics is a simple, open-source, lightweight, and privacy-friendly web analytics tool. ...

