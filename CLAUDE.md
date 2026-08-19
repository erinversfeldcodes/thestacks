# The Stacks — Claude Code Project Configuration

> An open-source, self-hosted book management and discovery platform.
> Dark-academic-meets-cottage-core aesthetic.

## Quick Reference

- **Canonical docs:** `docs/technical-architecture.md` (architecture), `docs/user-stories.md` (features), `docs/implementation-mapping.md` (story-to-code bridge)
- **Agent system:** `docs/agents/` (orchestrator + specialists), `AGENTS.md` (registry + routing)
- **Standards:** `docs/agents/standards/` (code quality, testing, security, protobuf, migrations)
- **Issues:** `issues/` (structured task backlog, one `.md` per issue)
- **Plans:** `plans/` (orchestrator-generated implementation plans)
- **Proto schemas:** `proto/` (Protobuf contracts, `buf` config)

## Stack

| Component | Technology | Directory |
|-----------|-----------|-----------|
| Core API + orchestration | Elixir + Phoenix | `apps/core/` |
| Frontend SPA | Elm | `frontend/` |
| Vision service (Modal) | Python + FastAPI | `apps/vision/` |
| Bookshop price scraper | Rust microservice | `apps/scraper/` |
| Data transforms | dbt | `dbt/` |
| Schema contracts | Protobuf + buf | `proto/` |
| Infrastructure | Fly.io (IAD), Nix/Flox | `deploy/`, `nix/` |
| Database | PostgreSQL (op, wh, audit schemas) | `apps/core/priv/repo/migrations/` |

## Core Conventions

### ISBN Hard Gate
No book enters the system without a verified ISBN from Open Library or Google Books. This is non-negotiable.

### Event-Driven Architecture
All significant state changes emit events via `Stacks.Events.emit/1` to the `event_log` table. Oban delivers events to registered subscribers. See `docs/technical-architecture.md` section 21.

### Partner Integration
Partners (bookshops, reading groups, cafes) push data via JSON API validated against Protobuf-generated schemas. Partners never see user data. Platform owner approves all partners.

### Protobuf as Schema Contract
`.proto` files in `proto/` are the single source of truth for structured data. `buf lint` and `buf breaking` run in CI. JSON on the wire. Elm decoders are gitignored and regenerated at build time via `scripts/gen-elm-proto.sh`.

### GDPR by Default
4-tier data classification (public, personal, sensitive, external personal). Right to erasure, right to export. 30-day image retention. Consent with timestamps.

**Any change touching migrations, Ecto schemas, event emitters, user-data endpoints/routes, workers, or dbt models MUST pass the `gdpr-review` skill** (`.claude/skills/gdpr-review/`) — a per-diff lens proving each new piece of personal data is reachable by erasure (`GDPR.Deletion.delete_user_data/1` + the schema-guard — free-text must be deleted/anonymised, not just author-nulled), included in export (`GDPR.Export.export_user_data/2`), gated where required (`ConsentCheck`), and kept out of event_log/audit/warehouse. Run it as a lens during code-review for data-touching PRs.

### Testing Philosophy
12-layer test strategy across 4 execution environments (local offline, local->deployed, CI, CI->deployed). Two switches select the environment: `MIX_ENV=test` loads the mock roster in `apps/core/config/test.exs` (vision, ISBN, scraper, storage, geocoder, Brave/SearXNG, dbt runner…), and `BASE_URL` points Playwright and the `:deployed_only` ExUnit tests at a real stack instead. `E2E_EXPECT_*` flags turn a spec's skip-on-missing-precondition into a hard failure in CI. See `docs/technical-architecture.md` section 16.

## Project Tools MCP Server

A local MCP server (`scripts/mcp/project_tools.py`) is registered in `.mcp.json` and starts automatically with every Claude Code session. It exposes project-management operations as first-class tools — **always prefer these over reading and parsing issue or plan files manually.**

| Tool | Use instead of |
|------|---------------|
| `mcp__project-tools__get_issue(number)` | Reading `issues/NNN-*.md` directly |
| `mcp__project-tools__list_issues(status?)` | `ls issues/` + manual parsing |
| `mcp__project-tools__next_issue_number()` | Counting files in `issues/` |
| `mcp__project-tools__update_progress(number, note)` | Editing the Progress Notes section of an issue file |
| `mcp__project-tools__get_plan_status(issue_number)` | Reading `plans/NNN-*.md` directly |
| `mcp__project-tools__get_agent(name)` | Reading `docs/agents/*.md` to construct subagent prompts |
| `mcp__project-tools__create_issue(title, summary, ...)` | Copying `issues/TEMPLATE.md` and filling it in manually |
| `mcp__project-tools__run_e2e_gate(issue_number)` | Manually running `scripts/deploy-preview.sh` and parsing output |

Setup after a fresh clone: `python3 -m venv scripts/mcp/.venv && scripts/mcp/.venv/bin/pip install -r scripts/mcp/requirements.txt`

## Claude Code Hooks

Automated standards enforcement is configured in `.claude/settings.json` and activates automatically when Claude Code opens this project — no setup required beyond `just install-hooks`.

| Hook | Trigger | What it checks |
|------|---------|---------------|
| `PostToolUse` | After every file write/edit | Format check for the edited file (mix format, elm-format, cargo fmt, ruff, buf lint) |
| `Stop` | End of every response | Full lint suite for all changed files: format + credo + sobelow (Elixir), fmt (Elm/Rust), ruff (Python), buf (proto) |

If a hook fails, the error and a `Run: ...` fix command are surfaced inline. Fix and continue — the session won't proceed past a Stop hook failure.

Run `just install-hooks` after a fresh clone to ensure hook scripts have their execute bit set.

## Agent System

The orchestrator uses a **hybrid execution model** (decided in Issue #024): orchestrator protocol for planning, gates, and mandatory stops; Agent Teams teammates for parallel specialist execution. `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` is configured in `.claude/settings.json`.

Invoke the orchestrator for multi-phase work:
```
You are The Stacks Orchestrator.
Load: docs/agents/orchestrator-agent.md
Task: Issue #NNN or [description]
```

For narrow, well-understood tasks, invoke a specialist directly:
```
You are The Stacks elixir-agent.
Load: docs/agents/elixir-agent.md
Task: [description]
```

See `AGENTS.md` for the full registry and domain routing table. See `docs/agents/decisions/agent-teams-evaluation.md` for the hybrid approach rationale.

## Code Style

- **Elixir:** `mix format`, `mix credo --strict`, Sobelow for security. Contexts as bounded domains. Pattern matching over conditionals.
- **Elm:** `elm-format`. Model-Update-View. No ports unless absolutely necessary. `RemoteData` for all API calls.
- **Rust:** `cargo fmt`, `cargo clippy`. Error handling via `thiserror`/`anyhow`. TOML configs per scraper.
- **Python:** `ruff` for linting/formatting. Type hints everywhere. FastAPI with Pydantic models.
- **SQL/dbt:** Lowercase, snake_case. All tables UUID PKs + TIMESTAMPTZ. dbt models: staging -> intermediate -> marts.
- **Protobuf:** `buf lint`. Field numbers are forever. Never reuse a number. Additive changes only.

## Shell & Bash Conventions

Bash commands run under the user's shell (**zsh**). To avoid the recurring "no matches found" failures:

- **Quote globs and brace-expansions** passed to any command: `ls "plans/124-"*state*.json`, `git show "HEAD:issues/124-"*.md`, `grep -rn "pat" "apps/core"`. Unquoted `**`, `*foo*`, and `{a,b,c}` are expanded by zsh *before* the tool runs and abort the whole command when nothing matches.
- **Prefer `find` / `ls dir/ | grep`** over bare recursive globs for discovery: `find apps/core -name "*book_detail_cache*"`, not `apps/core/**/*book_detail_cache*`.
- **Run long commands in the background.** Deploys, `just verify`, full test suites, E2E, and dialyzer PLT builds should use `run_in_background: true` and be polled via their log — don't block a foreground call. Foreground `sleep` is blocked.
- **Load `.env` before scripts/mix tasks that need runtime secrets** (`CLOAK_KEY`, `DATABASE_URL`, `FLY_API_TOKEN`): `set -a; source .env; set +a`. Many `scripts/*.sh` and `mix` tasks fail without it.

### Toolchain — NEVER run bare `mix` / `elixir` from a non-direnv shell

The Elixir toolchain is pinned by `flake.nix` (**Elixir 1.18.4 / OTP 28**, via `beam.packages.erlang_28.elixir_1_18` — see Issue #300), activated in interactive shells via direnv (`.envrc` = `use flake`). **A non-interactive shell — an AI agent's Bash tool, a git hook, or CI — gets NEITHER direnv NOR nix on PATH, so bare `mix`/`elixir` silently falls back to a SYSTEM Elixir (e.g. Homebrew 1.19.5 / OTP 28).** Compiling `_build` with the system toolchain and then loading those beams under the flake toolchain (as the pre-push hook and `just ci` do via `nix develop`) corrupts `_build` — you get `corrupt atom table` on core modules (`Elixir.Inspect`, `Elixir.List.Chars`), and stale/again-missing dialyzer PLTs. Symptoms recur after every clean rebuild until the toolchain stops being mixed.

- **Run Elixir tooling through the pinned shell, never bare.** Use the `just run` wrapper (added for this): `just run mix test`, `just run mix dialyzer`, `just run just verify`, `just run just ci`. It puts nix on PATH (`/nix/var/nix/profiles/default/bin`) and execs under `nix develop`; it's a no-op wrapper when already inside the dev shell (`STACKS_DEV_SHELL=1`).
- **`just doctor`** reports whether the bare-shell Elixir matches the pinned one — run it first if you see `corrupt atom table` or dialyzer "no PLT found" errors.
- **If `_build` is already poisoned:** `rm -rf _build` then rebuild via `just run just verify` (single, consistent toolchain). Don't interleave a bare `mix …` call in between — that re-poisons it.
- **DB roles after fresh-DB:** the `test-elixir`/fresh-DB path can leave `stacks_dbt` (and `stacks_app`/`stacks_readonly`) as `NOLOGIN`, breaking `dbt: checkpoint` (`role "stacks_dbt" is not permitted to log in`). Re-apply with `psql -h localhost -U postgres -d postgres -c "ALTER ROLE stacks_dbt WITH LOGIN;"` (also `stacks_app`, `stacks_readonly`). The `fix_db_role_login` migration should make this idempotent — a known follow-up.

### Working in a git worktree — run `just bootstrap-worktree` first

Agents build in isolated worktrees. A worktree shares git refs with the main checkout but **not its untracked files**, and this repo keeps a lot of load-bearing state untracked on purpose: `.env`, the proto-generated `apps/core/lib/stacks/gen/` tree, the generated Elm/Python/Rust proto artefacts, and the esbuild `priv/static/index.html`. So a fresh worktree does not compile, and the failures mislead — `Stacks.Accounts.User` "does not exist" (it is generated), or three `PageControllerTest` failures that read like a code defect but are a missing static asset.

```sh
just bootstrap-worktree            # from INSIDE the worktree; idempotent; no-op in the main checkout
just bootstrap-worktree --from /path/to/main/checkout   # if it can't infer the source
```

It seeds the untracked state, runs `mix deps.get`, generates **all five** codegen targets (generating only the Elixir pair leaves `lint-proto.sh` failing for reasons unrelated to your change), and then runs `mix proto.sync --check` to prove the seed wasn't stale.

⚠️ **`mix proto.sync` is cyclic**: it is a Mix task inside `apps/core`, but `core` cannot compile without the schemas it generates. Seeding `gen/` from the main checkout is what breaks the cycle — which is why copying it is a step and not a shortcut.

## Preview Deploys & E2E

The preview core VM is **512 MB**. Run heavy release tasks (the full `seed/0`) via `/app/bin/core rpc '…'`, **never `eval`** — `eval` spawns a second BEAM that OOMs the VM (`fly machine exec … EOF`, ~11s, no stacktrace). The preview seed uses `Stacks.Release.seed_live/0` (rpc, runs in the live node). Because it runs the full dev-fixture seed inside whatever node it hits, `seed_live/0` **must be prod-guarded** on a persistent preview-only env (e.g. `STACKS_E2E_TEST_HELPERS`) — the `ALLOW_SEEDS` inline gate can't survive `rpc`, and "only called in the preview branch" is not a sufficient guard on its own.

- **Deploy a preview locally (core-only, no Modal):** `SKIP_VISION=1 STACKS_SKIP_RESOLVER_PREFLIGHT=1 bash scripts/deploy-preview.sh` (needs `.env`'s `FLY_API_TOKEN` + `NEON_STAGING_*`; `SKIP_VISION` drops the `modal` CLI dep).
- **E2E against a preview:** `cd e2e && BASE_URL=https://<preview>.fly.dev npx playwright test --project=setup` then `--project=chromium` (already excludes the Modal-dependent `upload*`/`rate-limit` specs).
- Preview machines **auto-stop when idle** → a cold hit 502s (`auth.setup` "login failed HTTP 502"); warm `/api/health` or re-run — not a real failure.
- The preview seed only runs when the PR changes `seeds.exs`; else it inherits staging via Neon copy-on-write. `fly … exec … EOF` is the Issue #171/#177 flake.
- **Age-gate E2E needs `AGE_GATING_ENABLED=true` (ADR-020).** Age-gating ships dark — default OFF outside `:test` — so `age-gate.spec.ts` (and the age-gate slice of `public-profile.spec.ts`) only passes with the flag on. It is set automatically on the **preview stack** (`scripts/deploy-stack.sh`, preview branch only, alongside `STACKS_E2E_TEST_HELPERS`) and on the **local/CI Phoenix** (`scripts/test-e2e.sh`). Running Phoenix by hand for a local age-gate E2E? export `AGE_GATING_ENABLED=true` before `mix phx.server`. Prod stays off by design. The specs flip `age_verified` via the `STACKS_E2E_TEST_HELPERS`-gated helper `PUT /api/test/age-verification {email, verified}` (self-declared endpoint removed).

## Do Not

- Skip ISBN verification for any book entering the system
- Store partner API keys in plaintext (Argon2 hash only)
- Trust vision model output without validation (always verify ISBNs against Open Library/Google Books)
- Expose user data to partners (one-directional: partner -> platform)
- Delete events from `event_log` (immutable, except GDPR erasure of PII in payloads)
- Use `unsafe-eval` in CSP (Elm doesn't need it)
- Add Kafka, RabbitMQ, or any external message broker (Oban is the event bus)
