# Data Licensing Program — Design & Risk Education

> **Status:** In design. Living document.
> **Last substantive update:** 2026-04-15
>
> This document has two audiences:
> 1. **Us, designing the program** — decisions, tradeoffs, open questions.
> 2. **Users deciding whether to opt in** — the risk-education sections are written
>    in plain language and are the source material for the eventual in-app copy,
>    privacy policy wording, and consent UI.
>
> When in doubt, be honest about limits rather than reassuring about mitigations.
> Users who opt in after reading an honest account of the risks are the only
> consent worth having.

---

## 1. Purpose

AI training data is running out. The data that remains scarce — and valuable —
is **process data**: how people decide, revise, abandon, connect, participate.
Most public corpora contain outputs (finished reviews, completed purchases,
published essays). The Stacks sits on a joined trajectory of intention →
reading → revision → transaction → cultural participation, bound together by
ISBN.

We want to make that dataset available to AI researchers and, selectively, to
data brokers — on terms that:

- Compensate users for contributions (revenue share, not just "free service").
- Require explicit, per-purpose, revocable consent.
- Make downstream deletion a contractual obligation with audit rights.
- Preserve user ownership in the operative sense: a user who revokes consent
  has their contributions removed from the dataset and, through contract,
  from every downstream buyer.

This is deliberately a different stance from the ad-tech / data-broker default.
We are not monetising users; we are selling a joint product they are the
co-owners of.

---

## 2. What This Is, Plainly

> *(Source material for user-facing copy.)*

If you opt in, some of the data you generate on The Stacks — your reading
history, your writing, the way you interact with the writing assistant, your
marketplace activity — becomes part of a dataset we license to other
organisations who want to train AI models or study reading behaviour.

You get paid. You can turn it off at any time. When you do, your data is
removed from the dataset we hold, and every organisation that bought a copy
is contractually required to delete your contributions from theirs too.

This is not the only way your data is used — the normal features of the
platform (your library, the writing assistant, search) use your data to make
those features work. This is a separate, opt-in program on top.

You should read Section 4 before deciding. It explains honestly what can and
can't be guaranteed once data leaves our systems.

---

## 3. Data Tiers

Each tier has a distinct risk profile and value profile. Consent is granular
per tier — opting into one does not opt you into any other.

| Tier | Contents | Training Value | Re-ID Risk | Default Aggregation |
|------|----------|----------------|------------|---------------------|
| **T1 — Shelf behaviour** | Placements, moves, abandons, rereads, format choices | High (preference trajectories) | Medium | Per-user events OK with k-anon |
| **T2 — Marketplace signals** | Condition grades, price-at-sale, time-to-sell, listing outcomes | High (scarce: second-hand with outcome) | High for individual rows | Aggregate to per-ISBN distributions |
| **T3 — Third-space venues & events** | Venue metadata, event metadata, author links | Medium (novel: literary geography) | Low (public entities, opt-out flag already exists) | Per-row OK |
| **T4 — Writing assistant interaction metadata** | Prompt IDs, retrieved books, feedback signals, session depth, mode distribution, time-to-revision | Very high (prompt-effectiveness, retrieval quality, behavioural RLHF) | Medium (retrieval-set fingerprinting) | Per-session w/ k-anon, or aggregate to book/prompt |
| **T5 — Writing assistant dialogue prose** | Actual turn text (user + assistant) | Highest (Socratic dialogue pairs with feedback labels — nearly nonexistent publicly) | Very high (style fingerprint) | Per-turn with strong consent gate |
| **T6 — Blog post prose** | Published and/or private post text | Highest (long-form grounded prose) | Very high (style fingerprint + public cross-link) | Per-post with strong consent gate |

### 3.1 Current Design Decision: Prose Included (T5, T6)

We are designing the initial program with prose tiers (T5, T6) included rather
than metadata-only. Rationale:

- Prose is the highest-value signal and the thing no other dataset has.
  Excluding it trades away the core product.
- The honest position is that prose is identifying and we should say so rather
  than pretend DP noise solves it. Users who opt in with open eyes are better
  positioned than users who opt in under the illusion of anonymisation.
- Tiering allows users to opt into T1–T4 (lower risk) without touching T5/T6.
  Prose consent is a separate, louder gate with higher compensation.

See Section 4.1 for the honest risk copy that will accompany the prose-tier
consent flow.

---

## 4. Risks — Honest Enumeration

> *(Written plainly; this is the education material.)*

### 4.1 Style Fingerprint (T5, T6)

Your writing style is close to unique. Sentence rhythm, vocabulary, the
specific concepts you reach for, the way you hedge or don't — together these
identify you almost as reliably as your name. Removing your name from a blog
post or an assistant dialogue turn does **not** make it anonymous. Anyone who
has read your writing elsewhere — a public blog, a newsletter, a social post —
could plausibly match it.

**What we do about it:** The prose tier is a separate, explicit consent. You
are told exactly this before you opt in. You are compensated meaningfully for
it. Buyers of the prose tier are vetted and contractually restricted.

**What remains:** If a downstream buyer violates their contract, we can sue,
but we cannot un-identify you. Style fingerprinting is not a technical problem
we can solve — it is a property of prose. If that matters to you, do not opt
into T5 or T6.

### 4.2 Retrieval-Set Fingerprinting (T4)

Even without the text of your posts, the combination of books the writing
assistant retrieved for you — your specific antilibrary, your specific
reading pile, the particular books you revisit — is often unique on the
platform. Heavy readers with niche taste are the most identifiable. If your
shelf is public (US-10.2), someone who sees it can link it to your assistant
interactions in a T4 export.

**What we do about it:** Default T4 aggregation is **per-book or per-prompt,
not per-session**. We export "book X was retrieved N times, utilisation rate
Y, follow-up edit rate Z" rather than "user A retrieved these five books in
this session." Where per-session rows are needed, we enforce k-anonymity:
only rows where ≥k distinct users triggered the same retrieval pattern.

**What remains:** Aggregation reduces signal value for some research
purposes. We will sometimes choose to offer a less-aggregated T4 product
with an elevated consent gate; it will be separate from default T4.

### 4.3 Theme-Sequence Identifiability

If we extract topic labels from your posts ("this post is about grief /
colonialism / rationalism") and export the label sequence, the fingerprint
moves up one abstraction level. The sequence of themes you write about over
time is itself identifying. Coarser taxonomy reduces this (genre-level yes,
specific-topic no).

**What we do about it:** Theme labels, if included, are taxonomised at the
genre/domain level, not the specific-topic level. We do not export per-post
topic vectors.

**What remains:** Users who publish publicly under their own name have
already made their theme sequence public; T4 exports of that signal don't
materially increase exposure. Users with private blogs should consider this
carefully.

### 4.4 Behavioural Signatures at Small Scale

"The only user on the platform who triggered Challenge-mode against a
Stoicism book at 2am and edited their post within 15 minutes" is an
identifying fingerprint even with no text involved. On a large platform this
washes out. On a small platform it does not.

**What we do about it:** We will not export T1 or T4 rows that are unique or
near-unique (k<5) on their identifying dimensions. This means some
contributions are held back from exports, which is the correct behaviour.

**What remains:** Until the platform is large enough, this constrains
what can be exported. We will not paper over this by loosening k.

### 4.5 Cross-Linking With Public Blog Posts

If your blog post is published publicly, an attacker can read the public
post, guess which books it cites, and join that guess to a T4 row showing
which books the assistant retrieved in that session. Your prose is outside
the dataset but still on the internet pointing back at it.

**What we do about it:** T4 exports tied to publicly-published posts are
aggregated more aggressively than T4 exports tied to private drafts. Users
with public blogs are told this explicitly.

**What remains:** If you publish publicly, cross-linking is fundamentally
unavoidable. Opting out of T4 for publicly-published posts is supported.

### 4.6 Contractual Enforcement Has Limits

Once a dataset leaves our systems, technical revocation is effectively
impossible. What we can do:

- Content-address every dataset snapshot so we can prove a downstream copy
  was derived from our data.
- Publish a revocation ledger that buyers are contractually required to poll.
- Audit-right clauses and financial penalties for non-compliance.
- Refuse to sell to buyers who will not agree to these terms.

What we cannot do:

- Force a bad-faith buyer to delete data they have already ingested into a
  trained model. Weights are not easily un-trained. If your contribution was
  used to train a model before you revoked, that training is not reversible.
- Prevent a buyer from selling a copy to a fourth party in breach of
  contract, although we can sue and recover damages.

**What we do about it:** Buyers are vetted. Contracts are strong. Violations
are actionable. Users are told plainly that revocation is a contractual
guarantee, not a technical one.

**What remains:** There is a real gap between "we will make it costly for
them to cheat" and "cheating is impossible." Users deserve to understand this
before opting in.

### 4.7 Multi-Party Consent Problems

Some data involves multiple people. A reading-group discussion includes
every participant; one user's consent does not cover the others. Offer
negotiation threads include both buyer and seller. Blog comments involve
commenter and post author.

**What we do about it:**

- Reading-group discussions: either unanimous per-group opt-in (every member
  opts in or the thread is excluded), or export only aggregate topic-level
  signal.
- Offer threads: the offer *ladder* (sequence of amounts and outcome) is
  exportable with either party's consent; free-text messages require both
  parties' consent.
- Comments: post author consent governs the post; comment author consent
  governs their comment; a post with non-consenting commenters is exported
  with comments stripped.

**What remains:** Some of the richest data (full reading-group dialogue with
all participants consenting) is gated by coordination. That is correct.

---

## 5. Privacy Architecture

### 5.1 Consent Granularity

Consent is:

- **Per-tier** (T1–T6 are independent opt-ins).
- **Per-purpose** (AI training, brokered sale, academic research — separate
  opt-ins within a tier).
- **Time-boxed** (defaults to 12 months; user renews or lets lapse).
- **Revocable** (single-click in settings; revocation is immediate for our
  dataset and triggers downstream revocation obligations).

Implemented on top of the existing consent-with-timestamps infrastructure
(US-8.3).

### 5.2 Revocation Ledger

A publicly-verifiable, append-only log of revocation events. Structured like
Certificate Transparency for data erasure:

- Each dataset snapshot is content-addressed (hash).
- Each revocation is a signed tombstone against (dataset_hash, user_id).
- Buyers are contractually required to poll the ledger at a defined cadence
  and delete revoked contributions from their copies.
- Third parties (auditors, researchers, users themselves) can verify
  compliance by checking the ledger and challenging buyers.

### 5.3 Differential Privacy at Export

Where it makes sense (structured signals, bounded numerics), DP noise is
added at the export boundary. This does **not** apply meaningfully to prose
tiers — we do not pretend otherwise.

### 5.4 Revenue Share

Contributors are paid a proportional share of the **profit** from each sale,
defined against the same transparent cost-tracking infrastructure the platform
already publishes. Past payments are never clawed back on revocation. Full
design in Section 6.

### 5.5 Downstream Deletion Obligations

Boilerplate in every buyer contract:

- Buyer must delete revoked contributions within N days of ledger update.
- Buyer's downstream customers inherit the same obligation; buyer is
  responsible for flowing it down.
- Audit rights: we can request proof of compliance.
- Financial penalties for non-compliance.
- Right to refuse future sales to non-compliant buyers.

---

## 6. Revenue Share Model

Contributors receive a proportional share of the **profit** from each sale of
a dataset — not a share of gross revenue. "Profit" is defined against the
same cost-tracking infrastructure users can already see on the public costs
dashboard (US-5.1, backed by `mart_cost_tracking`). The ledger that shows
what the platform costs to run is the same ledger that shows what a sale
yielded after costs. There is no separate accounting system.

### 6.1 Profit Definition

For each sale of a dataset snapshot:

```
sale_profit = sale_revenue − attributable_costs
```

**Attributable costs** are drawn from the cost-tracking mart and include:

- Dataset preparation compute (DP noise, aggregation, k-anonymity passes,
  snapshot builds)
- Snapshot storage (R2)
- Revocation ledger operations
- Buyer administration and contract overhead
- A proportional share of general platform costs for the snapshot period
  (Neon, Fly, Modal, AI inference) — the allocation formula is published
  and auditable, not discretionary

If `sale_profit ≤ 0`, no contributor payout for that sale. The shortfall is
still published on the costs dashboard so users can see the math. A sale
that fails to cover its costs is absorbed by the platform, not distributed.

### 6.2 Proportional Share Formula

Each contributor's share is proportional to their **contribution units** in
the sold snapshot:

```
units_i  = Σ (rows_in_tier_t × tier_weight_t)
share_i  = units_i / total_units_in_snapshot
payout_i = share_i × sale_profit × contributor_pool_fraction
```

- **Tier weights** reflect both training value and personal cost of each
  tier. Higher-risk / higher-value tiers (T5 dialogue prose, T6 blog prose)
  carry larger weights than lower-risk tiers (T1 shelf events). Weights are
  published and **locked at snapshot creation time** — they cannot be
  retroactively changed.
- **Contributor pool fraction** is the portion of `sale_profit` distributed
  to contributors vs. retained by the platform for reinvestment, reserves,
  and non-contributor operational overhead. Published transparently.
  **Initial target: 70% to contributors, 30% to platform.**

### 6.3 Non-Recoupment on Revocation

**Past payments are never clawed back.**

When a user revokes consent:

- Their contributions are removed from the current dataset snapshot.
- Buyers are obligated to delete those contributions from their copies via
  the revocation ledger.
- Future snapshots no longer include the user.
- If a sale is a subscription (buyer pays for ongoing access to new
  snapshots), the user stops accruing payouts for future periods.
- **Any payout already received for past snapshots stands.** The user was
  paid for a contribution that was used; that payment is earned and
  irrevocable.

Two reasons this matters:

1. Clawback would create a perverse incentive to never revoke. The whole
   point of the revocation right is that it is costless to exercise.
2. Payment is for the use of the data *up to the point of revocation*,
   not for an indefinite license. The contribution was real, the use was
   real, the compensation is earned.

### 6.4 Snapshot Boundaries Are Load-Bearing

Because payouts are per-snapshot and non-recoupable, snapshot identity has
to be precise:

- Each snapshot is content-addressed (hash in the revocation ledger).
- Each snapshot has a **fixed contributor set** — every user whose consent
  was active at snapshot creation time, captured in
  `op.dataset_snapshot_contributions`.
- Each snapshot has **fixed tier weights**.
- Each snapshot's sales are accounted against *that snapshot's* contributor
  set, not against the current user base at sale time.

A user who opts in, contributes to snapshot v1, then revokes before snapshot
v2 is created is paid for every sale of v1 in perpetuity (or until v1 is
retired from sale). They receive nothing from v2, v3, etc. — but nothing
they have already received is at risk, and they continue to earn from v1 as
long as v1 keeps selling.

### 6.5 Transparency — Extending the Costs Dashboard

The existing costs dashboard (US-5.1) is extended to show, alongside
operational costs:

- Dataset snapshots created, with contributor counts and tier mix
- Sales per snapshot: buyer (or buyer category if confidential), revenue,
  attributable costs, profit
- Contributor pool total per sale
- Platform retained share per sale
- Aggregate lifetime payout to contributors
- **Per-user view** for the signed-in contributor:
  - Contribution units per snapshot they are in
  - Payouts per sale
  - Current balance
  - Lifetime earnings

Every number traces back to the same cost-tracking mart. Accounting is not a
separate black box; it is the public ledger, filtered to the signed-in user
where relevant.

### 6.6 Payout Mechanics

- Payouts accumulate in a user's balance; disbursed when balance exceeds a
  minimum threshold (proposed: R50) to avoid per-transaction fee erosion.
- Payout rail: Stripe Connect or equivalent (open question).
- Tax reporting: user responsibility; platform issues annual statements in
  jurisdictions where required.
- Alternative to withdrawal: users can donate their balance to a nominated
  library, literacy charity, or the platform itself — same ledger, different
  destination account.

### 6.7 Schema Sketch

```
op.dataset_snapshots
  id              uuid PK
  hash            text        -- content address
  tier_weights    jsonb       -- locked at creation
  pool_fraction   numeric     -- locked at creation
  period_start    timestamptz
  period_end      timestamptz
  created_at      timestamptz

op.dataset_snapshot_contributions
  snapshot_id     uuid FK
  user_id         uuid FK
  tier            enum (t1..t6)
  row_count       integer
  weighted_units  numeric     -- rows × tier weight at snapshot time
  PRIMARY KEY (snapshot_id, user_id, tier)

op.dataset_sales
  id              uuid PK
  snapshot_id     uuid FK
  buyer_id        uuid
  revenue_zar     numeric
  attributable_costs_zar numeric
  sale_profit_zar numeric     -- computed, stored for immutability
  sold_at         timestamptz
  terms_hash      text

op.contributor_payouts
  id              uuid PK
  sale_id         uuid FK
  user_id         uuid FK
  amount_zar      numeric
  computed_at     timestamptz
  paid_out_at     timestamptz -- null until disbursed
  payout_ref      text        -- Stripe or equivalent
```

All rows immutable once recorded. Revocation writes to a separate
`dataset_revocations` table and affects only future snapshot composition,
never past accounting rows.

---

## 7. Auditability of the Data Lifecycle

"Fully auditable" means three different parties can verify what happened,
each with appropriate access:

- **The contributor** — can see everything that has ever happened to their
  own data, with cryptographic proof of inclusion in (or exclusion from)
  any given snapshot, and a complete earnings trail.
- **An external auditor or regulator** — can independently verify that the
  platform honoured its commitments (consent, revocation, payout,
  downstream deletion) without needing to trust us.
- **A buyer** — can verify the snapshot they purchased is the snapshot we
  claimed to sell, can prove their revocation-polling compliance, and can
  attest their own deletions in a form third parties trust.

This is achievable because the architecture is already event-sourced
(`event_log`) and already treats snapshots as content-addressed derived
views. Auditability is about formalising the primitives, signing the
artefacts, and exposing the right surfaces.

### 7.1 Lifecycle Stages and Their Audit Artefacts

Every stage produces a signed, timestamped, content-addressed artefact. The
audit trail is the *sequence of these artefacts*, linked by hashes into a
chain.

| Stage | Artefact | Kind |
|-------|----------|------|
| Data generation | `event_log` row | Immutable append-only |
| Consent grant / change / revoke | Entry in **Consent Transparency Log** | Signed Merkle log |
| Snapshot composition | **Snapshot Manifest** (tier weights, pool fraction, contributor set hash, cost-mart hash, transformation lineage hash) | Content-addressed, signed |
| Snapshot derivation | **Lineage Records** (one per transformation pass) | Content-addressed |
| Sale | **Sale Record** (buyer ID, snapshot hash, revenue, attributable-costs hash, terms hash) | Signed |
| Profit computation | Deterministic from `sale_revenue − attributable_costs`, both hash-pinned | Reproducible |
| Payout computation | Deterministic from Snapshot Manifest + Sale Record | Reproducible |
| Payout disbursement | `payout_ref` from payment rail | Externally-verifiable |
| Revocation | Entry in **Revocation Transparency Log** | Signed Merkle log |
| Buyer polling | Buyer-signed attestation: "polled at time T, observed root R" | Signed |
| Buyer deletion | Buyer-signed attestation: "for snapshot S, the following user contributions have been deleted" | Signed |
| Snapshot retirement | Retirement Record citing drift metric value and snapshot hash | Signed |

### 7.2 Core Primitives

**1. Event log as source of truth.** All stages are, at root, derivable from
the event log. This is Kleppmann's event-sourcing model: snapshots,
manifests, sales, payouts, and revocations are *derived views* over the
event log. Losing a derived view is not a data loss — it is a replay
operation.

**2. Content-addressed derivations.** Every derived artefact is identified
by the hash of its contents. A snapshot is a Merkle root over its
contributor set; a manifest is a hash over its fields; a sale record is a
hash over its terms. Hashes are stored in the event log. Given the event
log, every derivation is reproducible bit-for-bit.

**3. Signed transparency logs.** Consent and revocation are the two streams
where external parties need to verify events happened without trusting us.
Both run as Certificate-Transparency-style signed Merkle logs:

- Append-only.
- Periodically-published signed tree heads (STH) with monotonically
  increasing sequence numbers.
- Inclusion proofs: we can prove "event X is at position i in the tree at
  STH_n" without revealing the tree.
- Consistency proofs: STH_n is an extension of STH_m.
- STHs published publicly; third-party monitors can independently download
  them and challenge inconsistency.

**4. Per-transformation lineage.** Every transformation applied to the data
on its way to a snapshot (DP noise pass, k-anonymity filter, l-diversity
check, tier aggregation, field masking) produces a Lineage Record:

```
lineage_record
  id                   uuid PK
  snapshot_id          uuid FK
  transformation_name  text
  transformation_version text
  parameters_hash      text        -- hash of (k, ε, field list, etc.)
  input_hash           text        -- hash of inputs
  output_hash          text        -- hash of outputs
  code_version         text        -- git SHA that ran the transformation
  executed_at          timestamptz
```

A buyer (or auditor) can ask "how was this snapshot derived?" and receive
an ordered list of Lineage Records whose input/output hashes chain together
from the event log to the final Snapshot Manifest.

**5. Trusted time.** Every signed artefact needs a trustworthy timestamp.
Options (open question): RFC 3161 timestamps from a commercial TSA;
anchoring STHs into a public transparency log such as Sigstore Rekor;
periodic anchoring into a public blockchain. Choice is a cost/credibility
tradeoff.

**6. Key hygiene.** Signing keys for the transparency logs are held in an
HSM or equivalent; rotations are themselves events; compromised keys
invalidate only the signatures issued after compromise and before rotation,
not the underlying log contents (which remain verifiable via the Merkle
structure).

### 7.3 User-Facing Surface: "My Data Timeline"

Every contributor has a `/settings/data/timeline` page showing, for their
own account only:

- Every consent grant / change / revoke with timestamp and signed ledger
  position.
- Every snapshot they were included in, with Merkle inclusion proof.
- Every sale of each of those snapshots, with profit computation they can
  re-run and their unit share derivation.
- Every payout with amount, computation inputs, and payment-rail ref.
- Every buyer that received a snapshot containing their contributions.
- For each buyer, the most recent revocation-polling attestation they
  signed and the most recent deletion attestation (if the user has revoked).
- If they have revoked: the revocation ledger entry with proof, and the
  downstream-deletion attestations received so far.

Every number on the timeline is traceable to an artefact hash. Users who
want to verify independently can pull the public STHs, verify their
inclusion proofs locally, and re-compute the profit and payout math from
the Sale Record and Snapshot Manifest.

This is the contributor's equivalent of the public costs dashboard: the
same radical transparency, filtered to what belongs to them.

### 7.4 Auditor-Facing Surface

For regulators, journalists, academic researchers, and independent monitors:

- **Public STH publication**: signed tree heads for the Consent and
  Revocation transparency logs, published on a schedule (proposed: every
  10 minutes, or on update, whichever is later).
- **Public snapshot manifests** (content only — not the snapshot data
  itself): tier weights, pool fraction, contributor set Merkle root,
  transformation lineage, buyer list, retirement status.
- **Public cost-mart snapshots**: the exact `mart_cost_tracking` state at
  the time of each sale, content-addressed and hash-pinned in the Sale
  Record, so the profit computation is third-party-verifiable.
- **Replay tooling**: open-source tool that takes an event log export and a
  snapshot manifest and reproduces the snapshot bit-for-bit.
- **Auditor program**: a defined process for independent auditors to
  request read-only access to internal artefacts for periodic review, with
  published findings.

### 7.5 Buyer-Facing Surface

Buyers receive, with every purchase:

- The snapshot itself (content-addressed).
- The Snapshot Manifest (transformation lineage, parameter hashes, code
  version).
- The Sale Record (hash-pinning everything they received).
- The most recent Revocation Transparency Log STH at sale time.
- A client library for polling the Revocation Log, verifying new STHs
  against the previous one (consistency proof), and identifying which of
  their held rows are affected.

Buyers return:

- Periodic signed polling attestations ("I polled at T, observed STH_n").
- Signed deletion attestations whenever they delete revoked contributions.

Failure to return these attestations on the agreed cadence is a contractual
breach, enforceable because the *absence* of an attestation is itself
observable in the audit trail.

### 7.6 Replay-Based Audit

The strongest guarantee the architecture provides: given the event log
alone, any downstream artefact can be reproduced. This is Kleppmann's "the
database is a cache of a decision log." A regulator or an internal audit
can, at any time, replay the log and verify that:

- The set of events with active consent at time T matches the contributor
  set of snapshot S created at time T.
- The attributable-costs value in Sale Record X matches the
  `mart_cost_tracking` state at time of sale.
- The payout amount to user U for sale X is exactly what the formula
  produces given the Snapshot Manifest and Sale Record.
- The revocation at time T for user U produced tombstones in the
  Revocation Log within the committed latency budget.

Anything that cannot be reproduced from the event log is, by design, not
part of the lifecycle. There is no off-ledger state.

### 7.7 What Is Not Claimed

Auditability does not prevent bad-faith behaviour; it makes bad-faith
behaviour *observable and provable*. Specifically:

- A buyer who trains a model and then fails to delete after revocation
  cannot be forced to un-train. Audit makes the breach provable and
  actionable, not preventable.
- A key compromise can produce fraudulent signatures for a window; the
  transparency-log structure bounds and exposes the window, but does not
  retroactively invalidate it.
- An insider with database write access could, absent the replay
  discipline, tamper with derived rows. Replay from event log is the
  defence: divergence between derived state and replayed state is itself
  an alarm.

---

## 8. Open Questions

A framework review against **GDPR**, **Martin Kleppmann** (event sourcing,
immutable logs, local-first software, verifiable ledgers), and **Chip Huyen**
(ML data quality, drift, lineage, feedback loops) resolved or sharpened
several of these. Resolutions recorded in 8.1; questions that remain open
but are now better framed in 8.2; new questions the frameworks introduced in
8.3.

### 8.1 Resolved via Framework Review (2026-04-15)

**Subscription vs. one-time sale** — *both supported; no defined horizon
required*. Each delivery of a snapshot under a subscription is a fresh
processing event under GDPR (Art 6) and a fresh derivation in Kleppmann's
event-sourcing sense. Revocation stops future deliveries immediately; past
payouts stand per non-recoupment. Subscriptions are simply a stream of
derived deliveries over an immutable snapshot.

**Snapshot retirement policy** — *drift-triggered, non-destructive*. A
snapshot is retired from sale when a published drift metric crosses its
threshold (Huyen) or when two or more newer snapshots exist. Retirement
means "no new sales"; prior buyers retain their copies subject to the
revocation ledger; prior contributors keep accrued earnings. The snapshot
is never destroyed (Kleppmann immutability).

**Dataset versioning — full-replace vs. append-with-diff** — *append-with-diff
only*. Full replace would break the immutability that non-recoupment depends
on. Each snapshot is a content-addressed artifact; buyers may hold multiple
versions; retirement is a release-policy decision, never a destruction event.

**Public-blog cross-linking mitigation** — *yes, offer a private-drafts-only
sub-tier for T4*. GDPR data minimisation supports exporting less linking
information when the source post is publicly published under the user's own
identity.

**"Freely given" consent under payment** — *structural commitment: no feature
of the platform will ever be gated by data-licensing consent*. The free
baseline experience must be equivalent to the paid-contributor experience.
This answers the EDPB concern that payment creates inducement: consent must
stand without the money, and does.

**Theme taxonomy (partial)** — *genre-level, versioned, with Art 9 flagging*.
Taxonomy is versioned per Huyen's lineage-as-first-class principle. Nodes
that map to GDPR special categories (health, religion, politics, sexuality)
trigger a separate sub-consent gate. Specific taxonomy content still open.

**Buyer vetting (partial) — minimum clauses identified**:

1. Lawful basis disclosed (GDPR Art 6).
2. Art 9 handling plan for any special-category inferences.
3. Operational data-subject interface (access, rectification, erasure).
4. Revocation-ledger polling commitment with audited cadence.
5. Feedback-loop non-propagation clause (Huyen): models trained on our
   data may not produce outputs fed back to our users without disclosure.
6. Eval hygiene commitment (Huyen): named held-out split retained for the
   buyer's own evaluation, never used in training.
7. Cross-border transfer safeguards (GDPR Art 44+): SCCs or adequacy for
   non-EEA buyers.
8. Sector exclusions: surveillance, predictive policing, targeted
   advertising, any use inconsistent with the platform's stated values.

Specific clause language per item still open (see 7.3).

### 8.2 Still Open — Now Better Framed

- **Aggregation thresholds for T4**: framework is k ≥ 5 as hard floor; l-diversity required for any tier touching Art 9 inferences. Specific numeric thresholds per tier/field TBD and must be published before first snapshot.
- **Tier weights**: framework is `weight = utility_factor × risk_factor`, published and locked at snapshot creation. Numeric weights per tier TBD.
- **General-platform-cost allocation formula**: revenue-weighted allocation of period costs (`period_cost × snapshot_revenue / total_revenue_in_period`) is the proposed deterministic formula, supporting Kleppmann's derived-view reproducibility. Needs numeric review against real cost data once we have any.
- **Prose-tier compensation multiple**: genuine tension between recognising elevated risk/value and the EDPB "freely given" concern about inducement for lower-income users. No source resolves this; requires counsel input.

### 8.3 New Questions Introduced by Framework Review

**From GDPR:**
- **DPIA (Art 35)** — commission before launch. Scope, reviewer, publication status?
- **Genre → Art 9 mapping** — which taxonomy nodes trigger the special-category sub-consent? At what confidence threshold?
- **Joint controllership (Art 26)** — when does a buyer's co-specification of dataset composition cross from "separate controller" into joint control? Liability-allocation agreement needed for the edge cases.
- **Breach notification chain (Art 33/34)** — buyer-side breach must flow back to our affected users. Contractual obligation plus user-facing notification mechanism.
- **Research-tier "appropriate safeguards" (Art 89)** — specifically what? Ethics-board letter, institutional processor agreement, publication-only-of-aggregates?
- **Written "consent stands without payment" position** for counsel review; accompanying language in the consent UI.

**From Kleppmann:**
- **Revocation ledger as signed Merkle log** (Certificate-Transparency-style): which signing scheme, what publication cadence, is there a third-party auditor program?
- **Event log retention at 10+ year horizon under repeated GDPR erasure of PII payloads** — does the event-shell-only approach remain sound? Compaction / archival policy?
- **Replay-based audit tooling** — can we rebuild a contributor's full payout history from the event log alone as a routine admin operation? Required for local-first-style user verifiability.

**From Huyen:**
- **Feedback-loop non-propagation**: measurable contractual commitment, not aspirational language. What exactly does a buyer agree to, and how is violation detected?
- **Eval hygiene enforcement**: do we require buyers to name their held-out split publicly, or just commit in principle?
- **Snapshot vintage as first-class metadata**: format (ISO date + hash?), buyer-facing exposure, user-facing display on the costs dashboard.
- **Drift metric(s)**: which metric(s) drive retirement? Who monitors? Alert threshold and dashboard surface?
- **Per-transformation lineage inside a snapshot**: do we record which DP / aggregation / k-anon passes touched each row, and expose that to buyers for reproducibility?
- **Responsible-AI framework alignment**: should buyer-facing terms be structured against a published standard (NIST AI RMF or equivalent) to reduce ambiguity?

---

## 9. Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-04-15 | Include prose tiers (T5, T6) in initial design | Core product value; addressed via consent transparency and tier separation rather than false anonymisation claims |
| 2026-04-15 | Default T4 aggregation to book/prompt level, not per-session | Retrieval-set fingerprinting risk; per-session available as separate higher-gate tier |
| 2026-04-15 | Reading-group discussions require unanimous per-group opt-in for prose export | Multi-party consent problem; coordination cost is correct |
| 2026-04-15 | Revenue share is proportional to **profit**, not gross revenue; accounted against the same public cost-tracking mart | Transparency requires one ledger, not two; users see the same costs math as the platform does |
| 2026-04-15 | Non-recoupment on revocation — past payouts are never clawed back | Clawback would make revocation costly and defeat its purpose; payment compensates use up to revocation, not an indefinite license |
| 2026-04-15 | Snapshot-scoped accounting — contributor set, tier weights, and pool fraction locked at snapshot creation | Required for non-recoupment to be coherent and auditable |
| 2026-04-15 | Initial contributor pool fraction target: 70% contributors / 30% platform | Starting point for transparency; revisit once real sale data exists |
| 2026-04-15 | Subscription sales supported without mandatory horizon; each delivery is a fresh processing event and a fresh derivation | GDPR Art 6 fresh-processing model; Kleppmann event-sourcing semantics |
| 2026-04-15 | Snapshot retirement is drift-triggered and non-destructive | Huyen on distribution shift; Kleppmann on immutability |
| 2026-04-15 | Dataset versioning is append-with-diff; full-replace is disallowed | Required for non-recoupment to remain coherent (Kleppmann) |
| 2026-04-15 | Private-drafts-only T4 sub-tier offered to mitigate public-blog cross-linking | GDPR data minimisation |
| 2026-04-15 | No platform feature will ever be gated by data-licensing consent; free baseline must equal paid-contributor experience | GDPR Art 7 + EDPB guidance on "freely given" consent under payment |
| 2026-04-15 | Theme taxonomy is genre-level and versioned; Art 9 nodes trigger a separate sub-consent | GDPR Art 9; Huyen lineage-as-first-class |
| 2026-04-15 | Buyer-vetting minimum clauses defined (8 items, Section 8.1) | GDPR Art 6/9/28/44; Huyen on feedback loops and eval hygiene |
| 2026-04-16 | Every lifecycle stage produces a signed, content-addressed, timestamped artefact chained by hash into the event log | Replay from event log is the foundation of auditability (Kleppmann) |
| 2026-04-16 | Consent and revocation run as Certificate-Transparency-style signed Merkle logs with publicly-published signed tree heads | Third parties must be able to verify inclusion and consistency without trusting us |
| 2026-04-16 | Every derivation produces a Lineage Record with input hash, output hash, parameters hash, and code version | Buyer reproducibility and regulator verifiability (Huyen lineage-as-first-class) |
| 2026-04-16 | Contributors get a self-serve "My Data Timeline" surface with cryptographic proofs for every event affecting their data | Radical transparency at user scope, mirroring the public costs dashboard |
| 2026-04-16 | Buyers return signed polling and deletion attestations; absence of attestation is itself observable and constitutes breach | Makes revocation compliance enforceable without requiring buyer honesty |
| 2026-04-16 | No off-ledger state: anything that cannot be reproduced from the event log is not part of the lifecycle | Auditability is a property of the architecture, not a reporting layer |

---

## 10. Not Yet Designed

- In-app consent UI flows (including "consent stands without payment" copy)
- Payout rail integration (Stripe Connect vs. platform credits vs. donation
  to nominated literacy charity)
- Costs-dashboard extension: per-user payout view, per-snapshot sales view,
  snapshot vintage display, drift-metric surface (extends US-5.1)
- Revocation ledger as a signed Merkle log (transparency-log style) —
  signing scheme, publication cadence, third-party auditor program
- DPIA (GDPR Art 35) — scope, commissioning, publication
- Genre → Art 9 taxonomy mapping and the sub-consent UI it triggers
- Joint-controllership playbook (Art 26) for co-specified-dataset edge cases
- Buyer-side breach notification chain back to affected users (Art 33/34)
- Research-tier license and its Art 89 "appropriate safeguards"
- Buyer contract boilerplate with the 8 minimum clauses (Section 8.1)
  specified in reviewable language
- Dataset schema (which proto messages are exportable, with what field masking)
- Per-transformation lineage inside a snapshot (which DP/k-anon/l-diversity
  passes touched each row) and buyer-facing reproducibility surface
- Replay-based audit tooling: rebuild a contributor's payout history from
  the event log alone, as a routine admin operation
- Drift metric(s) and retirement-trigger thresholds
- Responsible-AI framework alignment for buyer-facing terms (NIST AI RMF or
  equivalent)
- Admin tooling for buyer management and audit response
- Appeals process for users who believe their data has been misused
- Tax statement generation per jurisdiction

**Auditability infrastructure (new, 2026-04-16):**

- Consent Transparency Log and Revocation Transparency Log as signed
  Merkle logs — signing scheme (Ed25519 with HSM custody is the leading
  candidate), STH publication cadence, monitor/witness program
- Trusted-time source decision (RFC 3161 TSA vs. Sigstore Rekor
  anchoring vs. periodic blockchain anchor)
- `lineage_record` schema, writer workflow in dataset-preparation jobs,
  and buyer-facing reproducibility tool
- `/settings/data/timeline` page: design, API, client-side proof
  verification
- Public-artefact surface: published STHs, snapshot manifests, cost-mart
  snapshots tied to sales, and the retrieval/verification CLI
- Open-source replay tool: takes event-log export + snapshot manifest,
  reproduces snapshot bit-for-bit
- Buyer attestation format and ingestion pipeline; the "missing
  attestation = breach" alerting
- Key-rotation playbook and the rotation-as-event contract
- Independent auditor program: eligibility, scope, reporting,
  publication
