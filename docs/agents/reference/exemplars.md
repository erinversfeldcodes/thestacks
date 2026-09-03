# Reference Corpus — Code Quality Exemplars

The Staff Engineer's calibration set: real code and writing by the practitioners whose taste this
project aims at — **Evan Czaplicki**, **Richard Feldman**, **Loris Cro**, **Andrew Kelley**. Used
to answer "is our code good enough?" by comparison to how they actually solved the analogous
problem, rather than by assertion.

Consumed by `docs/agents/staff-engineer-agent.md` (see its **Reference Corpus** section for the
method). This is a **growing asset** — append verified entries as you find them.

**Verification status:** every entry below was fetched and confirmed on **2026-07-26** (repos via
the GitHub API and source reads; talks and posts via their linked pages). Four errors were caught
and corrected in that pass — see *Corrections log* at the foot of this file. Re-verify anything you
lean on hard: links rot, repos move, and this file is only as good as its last check.

## ⚠️ Rules for citing from this file

- **Confirm before citing.** The URLs below were live on the verification date; fetch the artifact
  again rather than trusting the row. Line numbers in particular are not recorded here because
  they rot fastest — find the construct yourself.
- **Never cite from memory.** A fabricated citation launders a guess as authority — strictly worse
  than no citation. If you can't verify it, drop the citation; the finding stands on its reasoning.
  (The corrections log exists because this rule was broken in this file's first draft.)
- **Record what you verify.** When you add an entry, include the URL you checked and the date.

---

## Evan Czaplicki — interface design, tooling as care

**Code**

| Artifact | Where | What it demonstrates |
|---|---|---|
| `elm/parser` | github.com/elm/parser | A deep module: a tiny combinator interface hiding a full backtracking state machine. `run : Parser a -> String -> Result (List DeadEnd) a` — a two-variant `Result` and no other exit path, so callers cannot receive an unenumerated outcome. |
| `elm/json` (`Json.Decode`) | github.com/elm/json | Decoding as composable values rather than a framework; failure is data (`Result`), never an exception. |
| `elm/core` | github.com/elm/core | Small, opinionated stdlib — study what was *left out*. `Maybe`/`Result` instead of null/exceptions. |
| `elm/html`, `elm/virtual-dom` | github.com/elm/html · github.com/elm/virtual-dom | The interface/implementation split: an utterly plain `Html` API over a heavily optimised diffing engine. Complexity pulled downward. |
| `elm/compiler` | github.com/elm/compiler — see `compiler/src/Reporting/` | Error-message construction as a first-class concern with its own subsystem, not an afterthought. |

**Talks / writing**

- *The Life of a File* — Elm Europe 2017. When a file has earned a split; splitting on
  data-structure boundaries, not line counts. Cited directly in the agent's taste section.
  → youtube.com/watch?v=XpDsk374LDE
- *Code is the Easy Part* — elm-conf 2016 keynote. The non-code work that determines whether code
  is good. → youtube.com/watch?v=DSjbTC-hvqQ
- *Let's Be Mainstream!* — Curry On 2015. Designing for the person who has to use the thing.
  → youtube.com/watch?v=oYk8CKH7OhE
- *Compilers as Assistants* — the Elm 0.16 release post, Nov 2015. Error messages as a designed
  product surface. → elm-lang.org/news/compilers-as-assistants
- The official guide, guide.elm-lang.org — prose style worth imitating in our own docs.

**Use for:** interface depth, sum types over loose records, decoder design, our Elm SPA generally,
and any judgment about error-message and developer-experience quality.

---

## Richard Feldman — application architecture at scale, opaque boundaries, data modelling

**Code**

| Artifact | Where | What it demonstrates |
|---|---|---|
| `rtfeldman/elm-spa-example` | github.com/rtfeldman/elm-spa-example — `src/Api.elm` | The canonical large-Elm-app structure. `Api` exposes the **type** `Cred` but not its constructor (`type Cred = Cred Username String`), so credentials can only be obtained via `login`/`application` — an opaque boundary enforced by the compiler. The best single reference for our `frontend/` module boundaries and `Session` handling. |
| `roc-lang/roc` | github.com/roc-lang/roc | Language design under a "friendly + fast" constraint; platform/application split as an information-hiding boundary. |
| `rtfeldman/elm-css` | github.com/rtfeldman/elm-css | Types eliminating a whole class of stringly-typed errors. |
| `rtfeldman/elm-validate` | github.com/rtfeldman/elm-validate | Validation returning structured errors; the "make the valid state a distinct type" move. |

**Talks / writing**

- *Making Impossible States Impossible* — elm-conf 2016. **The** source for that principle; note
  the attribution (Feldman's talk, not Czaplicki's). → youtube.com/watch?v=IcgmSRJHu_8
- *Make Data Structures* — Elm Europe 2018. Model the data first; the functions follow.
  → youtube.com/watch?v=x1FU3e0sT1I
- *Scaling Elm Apps* — Elm Europe 2017. When to split modules in a growing app; the counterpart to
  Czaplicki's *Life of a File*. → youtube.com/watch?v=DoA4Txr4GUs
- *Why Isn't Functional Programming the Norm?* — 2019. Adoption and ergonomics reasoning.
  → youtube.com/watch?v=QyJZzq0v7Z4
- *Elm in Action* (Manning) — worked examples of testing and structuring Elm.
  → manning.com/books/elm-in-action
- *Software Unscripted* (podcast) — ongoing design commentary. → shows.acast.com/software-unscripted

**Use for:** Elm app architecture, opaque types / minimal `exposing` lists, module-split timing,
data-model-first thinking, and translating "make impossible states impossible" into Elixir structs
and proto messages.

---

## Andrew Kelley — explicitness, resource ownership, data-oriented design

> **Note:** the Zig project's primary home has moved to Codeberg; the `ziglang/zig` GitHub repo is
> still live and citable as a mirror, but check Codeberg for current source.

**Code**

| Artifact | Where | What it demonstrates |
|---|---|---|
| `std.mem.Allocator` | `lib/std/mem/Allocator.zig` | A vtable-based interface (`ptr`/`vtable`, `alloc`/`resize`/`free`) passed as an **explicit argument** throughout the stdlib. No implicit or global allocator anywhere. The purest available example of "no action at a distance". |
| Error sets, `try`, `defer`/`errdefer` | `ziglang/zig` | The error path is visible in the signature and at the call site; cleanup is co-located with acquisition. |
| `std.ArrayList`, `std.HashMap` | `lib/std/` | Data structures that expose their costs; no surprise reallocation semantics. |
| The self-hosted compiler's data layout | `src/Air.zig`, `src/Zcu.zig`, `lib/std/zig/Zir.zig`, `lib/std/zig/Ast.zig` | Data-oriented design at scale — `MultiArrayList` (struct-of-arrays) and index handles over pointers, used pervasively in compiler internals for measured wins. |

**Talks / writing**

- *The Zen of Zig* — run `zig zen`, or see the `info_zen` block in `src/main.zig`. The closest
  thing to a rival text for our Zen-of-Python legibility axis. Verified verbatim lines include:
  "Communicate intent precisely." · "Favor reading code over writing code." · "Only one obvious way
  to do things." · "Compile errors are better than runtime crashes." · "Runtime crashes are better
  than bugs." · "Reduce the amount one must remember." · "Resource allocation may fail; resource
  deallocation must succeed."
- *A Practical Guide to Applying Data-Oriented Design* — Handmade Seattle 2021. Measurement-driven
  structural change; the antidote to "optimise later".
  → media.handmade-seattle.com/practical-data-oriented-design/
- *The Road to Zig 1.0* — Philly ETE 2019. Design rationale and what was deliberately refused.
  → chariotsolutions.com/screencast/philly-ete-2019-andrew-kelley-the-road-to-zig-1-0/
- *Unsafe Zig is Safer Than Unsafe Rust* — **2018** (not 2021).
  → andrewkelley.me/post/unsafe-zig-safer-than-unsafe-rust.html
- *Why Zig When There is Already C++, D, and Rust?* — 2017. Note this lives in the **official Zig
  docs**, not on Kelley's personal blog. → ziglang.org/learn/why_zig_rust_d_cpp/

**Use for:** hidden control flow (macros, implicit callbacks, action-at-a-distance in Oban wiring),
resource/transaction ownership visibility, error-path design, and treating performance shape as a
design property. **Translation warning:** the *mechanism* rarely transfers to Elixir/Elm — cite the
property (visible ownership, enumerated errors), never "add allocators".

---

## Loris Cro — software you can love, developer-facing surfaces

**Code**

| Artifact | Where | What it demonstrates |
|---|---|---|
| `kristoff-it/zine` | github.com/kristoff-it/zine | A static site generator built for joy of use; content model and template layer designed as a product, not a config format. |
| `kristoff-it/superhtml` | github.com/kristoff-it/superhtml | HTML language server / templating with genuinely helpful diagnostics — error quality as a feature. |
| `kristoff-it/zig-okredis` | github.com/kristoff-it/zig-okredis | "Zero-allocation client for all the various Redis forks" — client library API design: zero-allocation paths and types that describe the protocol rather than stringly-typed commands. |

**Talks / writing**

- *Software You Can Love* — Cro coined the phrase in a 2021 post; it became a conference (Milan
  2021, Vancouver 2022, Milan 2024). The source of our product axis: build things whose maintenance
  is pleasant, not merely correct. → kristoff.it/blog/software-you-can-love/ · softwareyoucan.love
- kristoff.it — his blog generally, for ongoing writing on open source, community, and tooling.

**Use for:** the "would I love maintaining this in two years?" judgment, developer- and user-facing
error copy, tooling ergonomics, and library/SDK API design (relevant to the reusable-SDK milestone
in `notes/phase-1-launch-extension.md`).

---

## Translation table — exemplar property → this codebase

The transferable part is always the **property**, never the syntax.

| Property demonstrated | Where it applies in The Stacks |
|---|---|
| Caller cannot construct an invalid value (opaque `Cred`) | Elixir structs built only via changesets; `Shelving.Placement` invariants; proto messages that can't encode nonsense; Rust newtypes over raw ISBN strings |
| Return type enumerates every outcome (`Parser.run`) | Tagged tuples/typed structs over shape-varying maps; Dialyzer then catches unhandled cases |
| Interface hides a state machine (`elm/parser`) | Phoenix contexts as deep modules — `place_book/3`, `abandon_book/2` over exposed Repo plumbing |
| Resource ownership visible at the call site (allocators) | Who owns the transaction / Oban job / connection; explicit `Repo.transaction/2` boundaries over ambient side effects |
| Error path in the signature (`try`, error sets) | No bare `_ -> :ok`; no `Maybe.withDefault` swallowing decode failures; no ignored `Result` in the scraper |
| One obvious way to do it (Zen of Zig + Zen of Python agree) | One way to emit an event (`Stacks.Events.emit/1`), one way to authorise, one way to check visibility |
| Errors are a designed surface (*Compilers as Assistants*) | API error bodies, Elm user-facing failure states, partner API validation messages |
| Data structures before functions (*Make Data Structures*) | Ecto schema + proto shape reviewed before the context functions that use them |

**Where the BEAM disagrees, the BEAM wins.** Elixir has its own mature taste (Valim's contexts,
OTP supervision, let-it-crash). A Zig or Elm pattern that fights it is not an improvement — note
the tension and move on.

---

## Corrections log

Kept as a standing reminder of why the verify-before-citing rule exists. The first draft of this
file was written from memory and contained four errors, all caught by a fetch-everything pass on
2026-07-26:

| Error in first draft | Correction |
|---|---|
| *Make Data Structures* attributed to Czaplicki | It is **Feldman's** talk (Elm Europe 2018). Moved to his section. |
| *Why Zig When There is Already C++, D, and Rust?* placed on andrewkelley.me | It lives in the **official Zig docs** (ziglang.org/learn/why_zig_rust_d_cpp/), not his personal blog. |
| *Unsafe Zig is Safer Than Unsafe Rust* dated 2021 | Published **2018**. |
| *Zig Interfaces for the Uninitiated* attributed to Loris Cro | **Fabricated attribution** — no such post exists on kristoff.it. The title belongs to KilianVounckx on zig.news (2022). Citation removed. |

Three of the four read as confident, permalink-able facts. That is precisely the failure mode:
a plausible citation is more dangerous than an absent one.
