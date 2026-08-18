# Local full-stack profile

Run The Stacks' side services on your laptop, on the same images and Dockerfiles
production runs, so the **pipeline mechanisms are provable here** rather than only
on a preview deploy.

Two questions this exists to answer without deploying anything:

1. Does a metric the app emits actually reach the store and render on the public
   `/metrics` page — or does the live section quietly say "unavailable"?
2. Does a scrape actually write a database row — or does it fail somewhere between
   the Rust service and `op.price_snapshots`?

Both are answered below as checklists with observed values, because "the code looks
right" has repeatedly not been the same thing as "the pipeline runs".

## What runs where

| Service | How it runs | Same as prod? |
|---|---|---|
| VictoriaMetrics | compose, `victoriametrics/victoria-metrics:v1.103.0` | image pin matches `deploy/fly.victoriametrics.toml` |
| Grafana | compose, built from `deploy/grafana/Dockerfile` | same Dockerfile, same anonymous-viewer env as `deploy/fly.grafana.toml` |
| SearXNG | compose, built from `deploy/searxng/Dockerfile` | same Dockerfile and baked 5-engine settings |
| Phoenix | native, `just run mix phx.server` | prod runs a release; the metrics/scraper seams are identical |
| Rust scraper | native, `cargo run` in `apps/scraper` | same binary, same store configs |

The scraper stays native on purpose: it resolves store configs from a `scrapers/`
directory relative to its working directory, and a native run reuses
`apps/scraper/target`, so containerising it costs a multi-minute Rust build and
buys nothing local.

> **Not to be confused with `just observe`.** `infra/local-observability/` also
> brings up VictoriaMetrics and Grafana, but VM *scrapes* `/internal/metrics`
> there. Production does not scrape — the app *pushes*. This profile pushes, which
> is what makes it a proof of the real path. Both bind `8428`, so run one or the
> other, never both.

## Bring-up

```sh
# 1. Side services (builds Grafana + SearXNG the first time; ~1 min).
just local-stack-up

# 2. Phoenix, with the seams pointed at them.
set -a; source .env; source .env.local-stack.example; set +a
just run mix phx.server

# 3. The scraper, in its own shell. SCRAPER_HMAC_SECRET must match Phoenix's.
cd apps/scraper && SCRAPER_HMAC_SECRET=local-dev-scraper-secret cargo run
```

Teardown: `just local-stack-down` (keeps the `vm-data` volume), plus Ctrl-C on
the two native processes.

On Apple Silicon the Grafana build prints `the requested image's platform
(linux/amd64) does not match the detected host platform (linux/arm64/v8)`. That
is expected and not a misconfiguration: `deploy/grafana/Dockerfile` pins an
amd64 digest, so it runs under emulation. It works; first boot is just slower.

| | |
|---|---|
| App | http://localhost:4000 |
| Public metrics page | http://localhost:4000/metrics |
| Grafana (no login) | http://localhost:3010 |
| VictoriaMetrics UI | http://localhost:8428/vmui |
| SearXNG | http://localhost:8888 |
| Scraper health | http://localhost:8080/health |

### The one configuration trap

`STACKS_METRICS_PUSH_URL` and `STACKS_METRICS_QUERY_URL` are **base** URLs.
`Core.PromEx.MetricsPusher.build_url/1` appends `/api/v1/import/prometheus` and
the `extra_label=app=…` query itself; `Stacks.Transparency.Prometheus` appends
`/api/v1/query`. Set either to a full endpoint path and every push 404s while the
live section renders exactly as it does when no data has arrived yet. See
`.env.local-stack.example` for the full seam list.

## Mechanism proof 1 — metric → store → public page

Each step names something you can *see*, so a break tells you which hop failed.

- [ ] **Store starts empty.** `curl -s localhost:8428/api/v1/label/__name__/values`
      returns `{"status":"success","data":[]}`. Do this first, or a later reading
      cannot distinguish today's push from last week's.
- [ ] **The app pushes.** ~15s after Phoenix boots, the same call lists
      `stacks_`-prefixed names. The pusher's interval is 15s.
- [ ] **The push is labelled correctly.**
      `curl -s --get localhost:8428/api/v1/query --data-urlencode 'query=stacks_fuse_state_state'`
      shows `"app":"thestacks-core"`. This label matters: every allowlisted
      transparency query filters on `app="thestacks-core"`, so a differently
      labelled push stores fine and renders nothing.
- [ ] **An action moves a counter.** Note
      `sum(stacks_router_dispatch_stop_duration_milliseconds_count{app="thestacks-core"})`,
      drive N requests, re-query. It should rise by exactly N, ~30s later —
      15s push interval plus VM's `--search.latencyOffset=15s`. An empty or
      unchanged result inside that window is the offset, not a failure.
- [ ] **The public page renders it.** `curl -s localhost:4000/api/transparency/metrics`
      → `live` is a **list**, not the string `"unavailable"`, and contains
      `breakers_healthy` with a numeric `value`.
- [ ] **Grafana reads the same store** (the operator-facing half of the same path):
      `curl -s "localhost:3010/api/datasources/proxy/uid/prometheus/api/v1/query?query=up"`
      returns data, and `localhost:3010/api/search?type=dash-db` lists the six
      dashboards under "The Stacks". The datasource `uid` must be `prometheus` —
      the dashboard JSON hard-codes it.

Observed on 2026-08-18 (Docker 29.5.2 / colima, macOS):

```
stacks_fuse_state_state{app="thestacks-core",fuse_name="brave_fuse"} = 1
min(last_over_time(stacks_fuse_state_state{app="thestacks-core"}[2h])) → 1

router dispatch count BEFORE: 2
  → 25 requests to /api/health
router dispatch count AFTER:  27      (rose after ~35s)

GET /api/transparency/metrics
  live is: 1 rendered signal(s)
    breakers_healthy: value=1.0 unit=boolean label='Circuit breakers healthy'
  durable entries: 5
```

**Expect one live signal, not six, on a quiet local stack.** Five of the six
allowlisted signals are `rate()`s over pipeline counters — ISBN resolution,
moderation classification, age-gate enforcement, GDPR exports, handler errors —
and those families do not exist in the store until that pipeline has actually
run. `Stacks.Transparency` renders whichever signals resolve and only reports
`:unavailable` when *all six* fail, so one signal is a healthy pipeline with an
idle app. To light up more, drive the corresponding flow (upload a book, request
a GDPR export) and re-query.

## Mechanism proof 2 — scrape → database row

- [ ] **Baseline the table.**
      `psql "$DATABASE_URL" -c "select count(*) from op.price_snapshots;"` — note it.
- [ ] **The scraper is up and has configs.** Its log says
      `loaded 2 store configs from "scrapers"`, and `/health` returns
      `{"service":"scraper","status":"ok"}`. Zero configs means you started it
      from the wrong directory.
- [ ] **Stores are scrapeable in the database.**
      `select name, scraper_module from op.bookstores where scraper_module is not null;`
      must return rows whose `scraper_module` matches a TOML under
      `apps/scraper/scrapers/` (`za/wordsworth`, `za/exclusive_books`). No rows →
      `TriggerPriceScrapeJob` logs "no stores configured" and exits `:ok` having
      done nothing, which looks like success.
- [ ] **Drive a real scrape** for an ISBN that exists in `op.book_editions`.
      `Prices.upsert_snapshot/1` returns `{:error, :unknown_edition}` for an ISBN
      the local database has never heard of, so the row silently never lands.
- [ ] **The row is there,** with a real price and a real URL.

Driven with `mix run`, against a second BEAM so it does not fight the running
server for port 4000:

```sh
set -a; source .env; source .env.local-stack.example; set +a
STACKS_SKIP_ENDPOINT=1 just run mix run -e '
  Stacks.Workers.TriggerPriceScrapeJob.perform(%Oban.Job{args: %{"isbn" => "9780385490818"}})
  Process.sleep(9_000)   # PricePipeline is Broadway; batch_timeout is 5s
'
```

Observed on 2026-08-18:

```
price_snapshots BEFORE = 0
price_snapshots AFTER  = 1

 store           | price_cents | currency | in_stock | url
-----------------+-------------+----------+----------+-----------------------------------------------------
 Exclusive Books |       41500 | ZAR      | t        | https://exclusivebooks.co.za/products/9780385490818
```

A real fetch against a real shop, so **this proof depends on the internet and on
that shop's markup.** One of the two configured stores returned a price for this
ISBN; the other returning nothing is a normal stock miss, not a broken pipeline.
Treat a zero-row outcome as "try another ISBN or store" before treating it as a
defect — but treat a zero-row outcome *with no scrape errors logged* as a real
finding, because that is what a silently broken persistence hop looks like.

## Driving the app as a logged-in user

The register → confirm → login flow costs a mail round-trip and shares the
`:auth` rate bucket. With `STACKS_E2E_TEST_HELPERS=1` set (it is, in
`.env.local-stack.example`) you can mint a confirmed session directly.

```sh
curl -sS -X POST localhost:4000/api/test/session \
  -H 'Content-Type: application/json' \
  -d '{"email":"me@thestacks.test","display_name":"Me"}'
```

`201` with `{token, user_id, email, display_name}`. The server enforces a hard
`.test`-domain allowlist, so this cannot mint a session for a real account.

Then, in the browser's devtools console on `http://localhost:4000`:

```js
localStorage.setItem("stacks-auth", JSON.stringify({
  token:       "<token>",
  userId:      "<user_id>",       // note: camelCase, and the response is snake_case
  email:       "<email>",
  displayName: "<display_name>",
}));
location.reload();
```

⚠️ **The blob must be FLAT.** Nesting the identity fields under a `user` key — the
shape the API response and most people's instinct both suggest — fails silently:
the SPA boots, no error appears anywhere, and the app looks exactly like a
logged-out session. The key names are `userId`/`displayName` (camelCase) while the
mint response is `user_id`/`display_name` (snake_case); this is the exact shape
the Elm `saveAuth` port writes, and `injectSession` in `e2e/tests/helpers.ts` is
the executable copy of it.

Verify before blaming the UI:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" \
  localhost:4000/api/placements/mine        # 200 with the token, 401 without
```

## Restoring a staging dump

The local seed is fixtures. Some behaviour only shows up against real-ish account
data — long shelves, odd display names, users with history — and some E2E specs
skip for lack of it.

**Blocked on Neon recovery at the time of writing.** The procedure is recorded so
it is ready when the staging branch is reachable again; nothing else in this
document depends on it.

```sh
# 1. Connection string for the staging branch.
STAGING_URL="$(fly secrets list --app thestacks-core >/dev/null; echo "$NEON_STAGING_URL")"

# 2. Dump the op schema. --no-owner/--no-acl: local roles differ from Neon's.
pg_dump "$STAGING_URL" --schema=op --no-owner --no-acl -Fc -f /tmp/stacks-staging.dump

# 3. Restore over the local dev database.
dropdb --if-exists stacks_dev && createdb stacks_dev
pg_restore -d "postgresql://postgres:postgres@localhost:5432/stacks_dev" \
  --no-owner --no-acl /tmp/stacks-staging.dump
just run mix ecto.migrate          # staging may be behind local migrations

# 4. Delete the dump. It is real personal data.
rm -f /tmp/stacks-staging.dump
```

**The dump is local and ephemeral.** It carries real-ish account data, so it never
leaves the machine, never gets committed, never gets attached to an issue, and is
deleted as soon as the drive is done. Encrypted columns stay encrypted — reading
them needs the matching `CLOAK_KEY`, so use staging's, and do not re-key.

After a restore, `E2E_EXPECT_FULL_SEEDS=1` becomes usable locally:

```sh
cd e2e && E2E_EXPECT_FULL_SEEDS=1 npx playwright test --project=chromium
```

It converts the seed-data guard in `e2e/tests/helpers.ts` from a clean skip into
a hard assertion — turning "31 specs skipped, all green" into a real result. That
flag is only honest once the data is actually there; on the fixture seed it fails
for the right reason, which is not a useful signal.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Live section says `unavailable` | `STACKS_METRICS_QUERY_URL` unset, or set to a full path instead of a base URL |
| Metrics stored but page shows nothing | pushed under a different `app` label — the allowlist filters `app="thestacks-core"` |
| Query returns empty right after a push | VM's `--search.latencyOffset=15s` plus the 15s push interval; wait ~30s |
| Nothing pushes at all | `STACKS_METRICS_PUSH_URL` empty → `MetricsPusher.init/1` returns `:ignore` and the app boots silently without it |
| `MIX_ENV=test` ignores every var here | `config/runtime.exs` skips its whole non-test block under test, deliberately |
| Scraper 401s every request | `SCRAPER_HMAC_SECRET` differs between Phoenix and the Rust process |
| Scraper loads 0 store configs | started outside `apps/scraper`; it reads `scrapers/` relative to the working directory |
| `just local-stack-up` fails on a missing COPY source | `settings.rendered.yml` is generated by the recipe and gitignored; run it via `just`, not a bare `docker compose` |
| Port 8428 already allocated | `just observe` is running — the two stacks cannot coexist |
