import Config

config :core,
  ecto_repos: [Core.Repo, Core.ObanRepo],
  generators: [binary_id: true, timestamp_type: :utc_datetime_usec]

config :core, Core.Repo,
  migration_timestamps: [type: :utc_datetime_usec, inserted_at: :created_at],
  types: Core.PostgrexTypes

config :core, Core.ObanRepo,
  migration_timestamps: [type: :utc_datetime_usec, inserted_at: :created_at],
  types: Core.PostgrexTypes,
  priv: "priv/repo"

config :core, Oban,
  repo: Core.ObanRepo,
  plugins: [
    # ⚠️ `max_age` is explicit because Oban's DEFAULT is 60 — sixty SECONDS.
    #
    # With the default, a completed or discarded job row is deleted a minute
    # after it finishes, so `oban_jobs` reads empty on every stack and the
    # question "did the nightly job run?" has no answer in the database. That
    # is not a theoretical loss: this app's crontab fires 20 jobs on a machine
    # configured to scale to zero, so whether a given one ran at all is exactly
    # the thing an operator needs to know — and two runbook steps tell them to
    # check `oban_jobs`, where they will always find nothing.
    #
    # Seven days is chosen to span a weekly entry (the crontab has four) plus a
    # working week of lag before anyone looks. The pruner only touches
    # `completed`, `cancelled` and `discarded` rows, so raising this cannot
    # hide a backlog of `available`/`retryable` work.
    #
    # ⚠️ RAISING THIS IS NOT BEHAVIOURALLY FREE, and the reason is easy to miss
    # because it runs the other way from the usual worry.
    #
    # Oban's `unique:` checks READ retained rows — `@unique_defaults` carries
    # `states: :successful`, which includes `completed` (`deps/oban/lib/oban/
    # job.ex:228-233, 299`). This app has NINE `unique:` declarations and every
    # period exceeds sixty seconds: three at 86_400 (the two enrichment
    # discovery jobs and wishlist-availability), four at 3_600, two at 300.
    # Under the old window all nine were silently truncated to ~60s, because
    # the rows they query had already been deleted. They now hold for the
    # period they declare.
    #
    # That is a FIX in every case — the declared period was always the intent —
    # but it is a real change: wishlist-availability dedupe goes from ~60s to a
    # genuine 24 hours, and the two discovery jobs stop re-hitting Open Library
    # and Google Books for a book re-added within the day. If a notification
    # dedupe or an external-call volume moves after this, this is why.
    {Oban.Plugins.Pruner, max_age: {7, :days}},
    # ⛔ WITHOUT THIS, A JOB INTERRUPTED BY A MACHINE SUSPEND IS ORPHANED FOREVER.
    #
    # `deploy/fly.core.toml` sets `auto_stop_machines = true` and
    # `min_machines_running = 0`. A job that is `executing` when the machine goes
    # away never returns to `available` on its own — Oban has no way to know the
    # node died — and the Pruner above deliberately touches only `completed`,
    # `cancelled` and `discarded`, so nothing in the system ever collects it.
    #
    # Measured on production before this was added: all 91 `oban_jobs` rows were
    # in state `executing` and nothing else. `IdentifyBookJob` held 76 of them,
    # stale between 97 and 180 days, six already at `attempt = 3` of 3 so they
    # could never be retried and never completed. `ImageRetentionJob` held the
    # other 15 — which is why the 30-day image-retention promise had gone unmet
    # for 151 days while every gate stayed green.
    #
    # ⚠️ `rescue_after` must exceed the longest legitimate job, or this plugin
    # becomes a duplicate-work generator: it would return a still-running job to
    # `available` and a second node would pick it up. The retention sweep is the
    # longest, bounded by its own two 30s budgets plus the orphan check, and
    # vision jobs carry their own timeouts well under this. 15 minutes clears
    # that with room to spare while still being far shorter than the 97 days
    # these rows actually sat for.
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(15)},
    # ⚠️ EVERY ENTRY BELOW IS UNRELIABLE BY CONSTRUCTION, and the three that are
    # absent are absent for that reason.
    #
    # `deploy/fly.core.toml` sets `min_machines_running = 0`. Oban's `Cron`
    # plugin computes due jobs on a tick from a RUNNING node and has no
    # catch-up pass, so an entry fires only if something else happened to wake
    # the machine in that minute; a machine woken at 06:03 never runs the 06:00
    # entry. This is not a schedule, it is a lottery weighted by inbound
    # traffic.
    #
    # Three duties have been moved out to GitHub Actions schedules, which run on
    # a runner that is always awake:
    #
    #   * the dbt refresh    -> .github/workflows/scheduled-dbt-refresh.yml
    #   * the costs refresh  -> .github/workflows/scheduled-core-jobs.yml
    #   * bookstore events   -> .github/workflows/scheduled-core-jobs.yml
    #
    # ⚠️ Each entry was removed TOGETHER WITH its replacement, in the same
    # change. Deleting an unreliable schedule on its own is not a fix: it turns
    # "runs when the machine happens to be awake" into "never runs", which is
    # strictly worse than the defect. If a future change removes an entry below,
    # it owes the same pairing.
    #
    # ⚠️ The remaining SEVENTEEN have the same defect, and EIGHT of them carry
    # retention or account-lifecycle duties — the 30-day image retention, GDPR
    # export artefacts, reader free text, the audit log, the session-token
    # sweep, and three account-expiry sweeps. Do not read their presence here as
    # evidence that they run. Whether any given one has ever run became
    # answerable only when the Pruner window above was widened from 60 seconds
    # to 7 days; before that, `oban_jobs` read empty either way.
    #
    # Nothing is added to this list. A new scheduled duty gets a workflow.
    {Oban.Plugins.Cron,
     crontab: [
       {"0 2 * * *", Stacks.Workers.ImageRetentionJob},
       {"15 * * * *", Stacks.Workers.ExportRetentionJob},
       {"30 2 * * *", Stacks.Workers.LibraryImportRowRetentionJob},
       {"0 4 * * *", Stacks.Workers.TriggerPriceScrapeJob, args: %{batch: true}},
       {"0 7 * * *", Stacks.Workers.FetchAuthorRSSJob},
       {"0 1 * * *", Stacks.Workers.ListingExpiryJob},
       {"0 3 * * 0", Stacks.Workers.RSSLivenessJob},
       {"0 8 * * *", Stacks.Workers.DiscoverAuthorSourcesJob, args: %{batch: true}},
       {"30 4 * * *", Stacks.Workers.BuildScraperIndexJob},
       {"0 5 * * 0", Stacks.Workers.MatchStoreCatalogueJob},
       {"0 6 * * 0", Stacks.Workers.GeocodeBookstoresJob},
       {"30 3 * * *", Stacks.Workers.CacheSweepJob},
       {"0 0 * * *", Stacks.Workers.GuardianTokenSweepJob},
       {"0 9 * * *", Stacks.Workers.ExpiredUnverifiedAccountsJob},
       {"30 9 * * *", Stacks.Workers.ExpiredInvitesSweepJob},
       {"45 9 * * *", Stacks.Workers.ExpiredEmailChangesJob},
       {"0 3 * * *", Stacks.Workers.AuditRetentionJob}
     ]}
  ],
  queues: [default: 10, events: 20, vision: 20, scraper: 5, notifications: 3, dbt_refresh: 1]

config :core, CoreWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [formats: [json: CoreWeb.ErrorJSON], layout: false],
  pubsub_server: Core.PubSub

config :phoenix, :json_library, Jason

# Request logging prints the parameter map at :info, so anything that is itself a
# credential has to be named here or it lands in the application log — and from
# there in whatever aggregates it. Substring matching, so "code" also covers
# `invite_code` and an MFA code, and "token" covers refresh and confirmation
# tokens. Phoenix's default is `["password"]` alone; setting this REPLACES that
# default, which is why password is restated.
config :phoenix, :filter_parameters, ["password", "code", "token", "secret"]

config :core, Stacks.Accounts.Guardian,
  issuer: "stacks",
  ttl: {8, :hours},
  secret_key: "change_me_in_production_via_runtime_exs_at_least_32_chars_long"

config :core, :session_absolute_cap, {7, :day}

config :core, :session_rotation_grace, {20, :second}

config :guardian, Guardian.DB,
  repo: Core.Repo,
  prefix: "op",
  schema_name: "guardian_tokens",
  token_types: ["access"]

config :core, :vision_client, Stacks.AI.Client
config :core, :isbn_http_client, Stacks.Books.HttpClient
config :core, :vision_service_url, "http://localhost:8000"
config :core, :vision_hmac_secret, "dev-only-hmac-secret-change-in-production"
config :core, :scraper_client, Stacks.Enrichment.ScraperClient
config :core, :scraper_service_url, "http://localhost:8080"
config :core, :scraper_hmac_secret, "dev-only-scraper-hmac-secret-change-in-production"
config :core, :brave_client, Stacks.Discovery.BraveClient
config :core, :together_client, Stacks.AI.TogetherClient
config :core, :searxng_client, Stacks.Discovery.SearxngClient
config :core, :searxng_url, "http://localhost:8888"
config :core, :dbt_runner, Stacks.Workers.DbtRunner
config :core, :transparency_prometheus_client, Stacks.Transparency.Prometheus
config :core, :rss_fetcher, Stacks.Enrichment.RssFetcher
config :core, :storage, Stacks.Storage.Local

config :core, Stacks.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1",
      key: Base.decode64!("47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="),
      iv_length: 12
    }
  ]

config :core, Stacks.Email.Mailer, adapter: Swoosh.Adapters.Local

# TODO(email): TEMPORARY STOPGAP sender — Resend's `onboarding@resend.dev` test
# address. It CANNOT deliver to real users: verified 2026-07 that Resend's
# onboarding mode only accepts the Resend-account owner's own email, AND only when
# the recipient has no display name (a `{name, addr}` "to" 403s). So real
# verification/reset emails will NOT reach actual signups with this sender.
# ACTION: once a domain is verified at resend.com/domains, flip this to
# `{"The Stacks", "noreply@#{canonical_domain}"}` (or set the EMAIL_FROM env var) — that
# is the ONLY remaining step to make prod email actually work. Overridable per-env
# via EMAIL_FROM (config/runtime.exs).
config :core, :email_from, {"The Stacks", "onboarding@resend.dev"}

# The domain the platform is served on — the ONE place it is named. Everything
# brand-bearing derives from this: the public cost page's registration line,
# privacy@ in email templates, and the eventual noreply@ sender. The codebase
# used to hardcode `thestacks.app` in those places while production actually
# serves `readinginthestacks.com` (thestacks.app is a parked lander) — so the
# public cost page named a domain the platform does not serve. Overridable at
# runtime via CANONICAL_DOMAIN (config/runtime.exs); change it there and every
# derived string follows.
config :core, :canonical_domain, "readinginthestacks.com"

config :swoosh, :api_client, Swoosh.ApiClient.Req

config :elixir, :time_zone_database, TimeZoneInfo.TimeZoneDatabase
config :time_zone_info, update: :disabled
config :tzdata, :autoupdate, :disabled

config :ex_aws, http_client: ExAws.Request.Req

config :core, :ai_budget,
  daily_limit_cents: 500,
  monthly_limit_cents: 5_000

config :core, :enrichment_confidence_threshold, 0.5

config :core, :login_lockout_threshold, 10
config :core, :login_lockout_window_seconds, 600
config :core, :login_lockout_duration_seconds, 900
config :core, :login_lockout_max_duration_seconds, 7_200
config :core, :login_lockout_backoff_window_seconds, 86_400

# Argon2id memory cost. Left unset, argon2_elixir defaults to m_cost 16
# (2^16 KiB = 64 MiB per hash). With ArgonPool bounding concurrency to 2 that is
# 128 MiB of peak hashing on a 512 MB VM whose BEAM baseline has grown with the
# app — the OOM the 0f4a5193 pool only band-aided. m_cost 15 (2^15 KiB = 32 MiB)
# halves per-hash memory (2×32 = 64 MiB peak) and still sits above the OWASP
# Argon2id floor of 19 MiB — so this is a root-cause fix, not a VM-size workaround.
# The cost is encoded in each stored hash, so existing passwords keep verifying;
# only new/rehashed passwords use the new cost.
config :argon2_elixir, m_cost: 15

import_config "#{config_env()}.exs"
