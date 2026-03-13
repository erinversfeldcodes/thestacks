# The Stacks

A self-hosted book management and discovery platform. Dark-academic-meets-cottage-core.

> **Status: Early development — pre-alpha, not production-ready.**
> The source code is publicly visible under a restrictive license. You may read it, but may not use, copy, or distribute it. See [LICENSE](./LICENSE).

[What it is](#what-it-is) · [What's been built](#whats-been-built) · [Architecture](#architecture) · [Documentation](#documentation) · [Issues & Feedback](#issues--feedback) · [License](#license)

---

## What it is

I can't be the only one: weak-willed to the lure of a book store, the only thing that saves my bank account from the siren's call of the turning of a page on a new book is the reminder of the dog-eared pile next to my bed and the uncracked spines already on my shelf at home. Nevermind the eBooks and audiobooks slowly encroaching on my device storage. So instead I snap a pic of the books I like the look of and promise myself I will return for them! Its the same on every social media platform: find yourself in the reader algorithm and suddenly your phone is complaining of lack of storage for all the screenshots of books you don't have time for. Even worse, when your dopamine hamster wheel eventually shows you the way to the real world via IRL reading groups or events at your local bookstore, you don't diarise it and realise months later that you missed the one chance you had to meet your favourite author.

The Stacks is the place all of that lands instead.

It's a self-hosted platform for managing the full life of a reader — not just the books you've finished, but the ones you mean to read, the ones you're circling, the ones sitting on the edge of your consciousness. Take your photos and your screenshots and collect your bookish wishlist on a shelf of its own. Let each book become a place for finding information about where to buy it, what others thought of it, a way to collect your writing about related topics and more. Manage your existing library between the pile of books you're reading (however slowly), the collection you've finished reading and the (hopefully, excitingly) much larger collection that you haven't yet. Nassim Taleb called this the *antilibrary*: the unread books that represent what you don't yet know, the experiences you've not yet explored or considered, and which are often more valuable than the ones you've already perused.

Beyond the personal, The Stacks connects to the places where reading actually happens: local bookshops, reading groups, third spaces. Partners can surface events, stock, and pricing. You can share shelves publicly, with a group, or keep them entirely private. The platform is built to be social in the way a good bookshop is social — unhurried, context-rich, and genuinely useful.

And for the books you've outgrown or which never really gelled with you, The Stacks helps connect them with new homes on others' shelves.

**Design principles:**

- **ISBN-gated** — every book in the system has a verified ISBN from Open Library or Google Books. No loose titles, no duplicates.
- **Antilibrary-first** — revel in how much you still have to read.
- **Real-world connected** — bookshop events, author tours and updates, live pricing from local book sources, and partner integrations without exposing user data to anyone.
- **Privacy-first** — 4-tier GDPR data classification baked into the schema. Partners never see user data and users maintain complete control over who can see their shelves and their writings.

---

## What's been built

The project is in active early development. Current progress:

- Core database schema with `op`, `wh`, and `audit` schemas — all migrations verified
- ISBN hard gate and book entry validation pipeline
- Visibility model and marketplace schema
- dbt staging layer for the data warehouse
- Protobuf schema contracts with `buf` lint and breaking-change checks
- Event-driven architecture via Oban (no external broker)
- GDPR-by-default 4-tier data classification
- CI test coverage for the core data pipeline
- Linting toolchain across all languages

The frontend, vision service, scraper, and partner integrations are under active development.

---

## Architecture

| Component | Technology | Directory |
|-----------|-----------|-----------|
| Core API + orchestration | Elixir + Phoenix | `apps/core/` |
| Frontend SPA | Elm | `frontend/` |
| Vision service (Modal) | Python + FastAPI | `apps/vision/` |
| Bookshop price scraper | Rust + Axum | `apps/scraper/` |
| Data transforms | dbt | `dbt/` |
| Schema contracts | Protobuf + buf | `proto/` |
| Infrastructure | Fly.io, Nix/Flox | `deploy/`, `nix/` |
| Database | PostgreSQL | `apps/core/priv/repo/migrations/` |

---

## Documentation

| Document | Description |
|----------|-------------|
| [`docs/technical-architecture.md`](./docs/technical-architecture.md) | Full system architecture |
| [`docs/user-stories.md`](./docs/user-stories.md) | Feature specifications |
| [`docs/implementation-mapping.md`](./docs/implementation-mapping.md) | Story-to-code mapping |
| [`docs/deployment/DEV_SETUP.md`](./docs/deployment/DEV_SETUP.md) | Maintainer development setup |
| [`docs/deployment/FLY_SETUP.md`](./docs/deployment/FLY_SETUP.md) | Fly.io deployment guide |
| [`CHANGELOG.md`](./CHANGELOG.md) | History of notable changes |

---

## Issues & Feedback

External contributions (pull requests) are not being accepted at this time. The project is maintained by a single developer in early development.

Bug reports and feature requests are welcome:

- [Report a bug](https://github.com/erinversfeldcodes/thestacks/issues/new?template=bug_report.md)
- [Request a feature](https://github.com/erinversfeldcodes/thestacks/issues/new?template=feature_request.md)
- [Ask a question](https://github.com/erinversfeldcodes/thestacks/issues/new)

All interactions are governed by the [Code of Conduct](./CODE_OF_CONDUCT.md).

To report a security vulnerability privately, see [SECURITY.md](./SECURITY.md).

---

## License

Copyright (c) 2026 Erin Versfeld. All rights reserved.

The source code is publicly visible for reference and learning only. Use, reproduction, distribution, and derivative works are not permitted. See [LICENSE](./LICENSE) for full terms.
