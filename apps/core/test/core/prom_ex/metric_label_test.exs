defmodule Core.PromEx.MetricLabelTest do
  @moduledoc """
      Per-LABEL guard for the metrics pipeline — the companion to the per-family
      audience classification.

      Two different things can go wrong with a metric, and the audience guard
      only catches one of them. It asks "may this family be seen?". This asks
      "what is attached to each sample?", and the answer matters for two
      independent reasons:

        * **Cardinality.** A Prometheus label is a dimension. A bounded label
          (`outcome`, `result`) costs a handful of series; an unbounded one (a
          handle, a title, a raw request path, an id) costs one series per
          distinct value, forever, and takes the whole store down with it.

        * **PII.** A label value travels to the metrics store, which has no
          erasure path, no consent gate and — for the families classified
          public — an anonymous reader. A person's name in a label is a
          disclosure that no later deletion can retract.

      Roughly a dozen comments across the plugin and the audience map assert
      exactly this property in prose: "a bounded, whitelisted atom", "NO-PII:
      emit ONLY the fact that a handle was set, never the handle value", "`code`
      is a whitelisted atom — never a message, URL, or anything unbounded".
      Nothing enforced any of it. These are those claims, made executable.

      ## The shape, and why it is this shape

      `@bounded_labels` is FAIL-CLOSED, like the audience map it sits beside: a
      metric carrying a label that is not listed fails, rather than a label
      having to be recognised as dangerous before it is caught. The dangerous
      case is the one nobody thought about, so it has to be the default.

      ⚠️ And the allowlist cannot bless a PII-shaped name. `@forbidden_segments`
      is checked against the labels actually in USE, so adding `:user_email` to
      the map with a confident-sounding reason still fails. That is deliberate:
      this project has already shipped a guard whose allowlist carried a written
      justification that was simply false, and nothing checked it. A
      justification a machine cannot check is a sentence, not a guard.

      ## Scope: all six registered plugins, held to two different standards

      ⚠️ This file used to read `StacksPlugin.event_metrics/1` and nothing else,
      while describing itself as a guard on "the metrics pipeline".
      `Core.PromEx.plugins/0` registers **six** — Application, Beam, Phoenix,
      Ecto, Oban and Stacks — so five of six were unchecked, and
      `MetricsPusher.push/1` POSTs `PromEx.get_metrics/1` wholesale with no
      filtering by the audience map. Every one of those labels was reaching the
      store this moduledoc describes as having no erasure path.

      The roster is now derived from `plugins/0`, so registering a plugin
      extends the guard automatically.

      The two standards, because the remedies differ:

        * **Project metrics** (`@bounded_labels`) keep the strict rule. We own
          the emit site, so "emit the fact and leave the identifier out" is an
          instruction someone here can follow, and a person-shaped key fails
          outright.
        * **Library metrics** (`@library_owned_labels`) are declared with where
          each bound comes from, read out of `deps/prom_ex` rather than inferred
          from the key. Nobody here can change those emit sites; the only levers
          are to accept the label or to stop registering the plugin.

      Three of those declarations are worth reading, because the key misleads in
      every case: `:path` is the matched ROUTE PATTERN from
      `Phoenix.Router.route_info/4`, not a request path; `:modules` is a COUNT,
      not a list; `:author` and `:sha` read `$GIT_AUTHOR`/`$GIT_SHA`, which this
      project never sets, so both are a single constant string. Each looked
      dangerous and is not.

      `@library_unbounded_labels` holds the one that genuinely is — `:host`, the
      raw client-supplied Host header — accepted explicitly with its mitigation
      and a pinned ceiling, so the map cannot become where awkward findings go
      to be forgotten.
  """
  use ExUnit.Case, async: true

  alias Core.PromEx.Plugins.Stacks, as: StacksPlugin

  # Every label key any registered metric attaches, and why its value set is
  # bounded. The reason is the point: it names where the boundedness comes from,
  # so the next person can check it rather than trust it.
  @bounded_labels %{
    action:
      "audit action verb, bounded at the emit site against a known set with everything " <>
        "else collapsing to \"other\" — NOT by the writer's signature, which takes any string",
    aggregate_type: "event aggregate kind — one of the domain's own nouns",
    bucket: "rate-limit bucket name, an atom named in the limiter's config",
    context: "where a token was issued (login vs refresh) — two values",
    direction: "which way a visibility change went — a small closed set",
    endpoint:
      "vision sidecar path, mapped from a fixed set by a function that RAISES " <>
        "on anything else, so an unmapped value cannot reach a label",
    event_type: "event name from the event log's own vocabulary",
    failed_step: "the name of the erasure step that failed — a Multi step key",
    feature: "consent feature key, whitelisted before it reaches consent",
    fuse_name: "circuit-breaker name, one per declared breaker",
    handler: "event-handler module name — bounded by the handler registry",
    outcome: "bounded outcome atom, per emit site",
    perspective: "view-as perspective, validated by the plug before use",
    phase: "pipeline phase name, declared in the telemetry wrapper",
    reason:
      "bounded failure-reason atom, never a message or an exception — true of the five " <>
        "registered producers, and NOT of every emit site carrying a `reason` key; see " <>
        "@free_text_reason_emitters",
    reason_class: "transport failure CLASS, deliberately a name rather than the failure",
    repo: "Ecto repo module name — the app declares two",
    resource_type:
      "domain resource kind. Bounded at the audit emit site the same way as `action`; the " <>
        "visibility emitters pass their own closed set",
    result: "ok / error style result atom",
    route_group: "coarse route family assigned by a plug, not a request path",
    source: "provenance tag, from a fixed set per emit site",
    category:
      "platform cost category — `validate_inclusion(:category, @platform_cost_valid_categories)` " <>
        "at the changeset, so the bound is code a machine can check",
    provider:
      "AI provider the budget tracker meters. ⚠️ NOT bounded by its caller — it arrives as " <>
        "`to_string/1` on a caller-supplied atom — so it is bounded AT THE EMIT SITE against " <>
        "`BudgetTracker.telemetry_providers/0`, with anything else collapsing to \"other\"",
    service:
      "platform cost service name. ⚠️ The COLUMN is free text with no validation, so this is " <>
        "bounded at the emit site against `Costs.telemetry_services/0` — the ten names the module " <>
        "itself writes — with anything else collapsing to \"other\". The row keeps the exact value",
    status: "HTTP status code — bounded by the protocol",
    template: "email template name, one per declared template",
    tier: "age-gate tier — a small closed ladder",
    type:
      "a bounded type atom — but from TWO producers with different vocabularies: login failure " <>
        "kinds, and the budget guard's :monthly / :daily period. Both are literals at their emit " <>
        "sites. Named per-producer rather than widened into a phrase that describes neither, " <>
        "which is the third time this shape has come up here",
    worker: "Oban worker module name — bounded by the worker set"
  }

  # ⚠️ Emit sites that put FREE TEXT in a `reason` metadata key, and so must
  # never have it promoted to a label.
  #
  # The guard above reasons over the metric REGISTRY, but boundedness is a
  # property of the PRODUCER. `@bounded_labels[:reason]` said "bounded failure-
  # reason atom, never a message or an exception", which is true of all five
  # registered producers and false of this one: `Audit.log_rollback/1` emits
  # `[:stacks, :system, :rollback]` with a `reason` taken from a workflow input,
  # i.e. operator free text. Nothing registers that event today, so there is no
  # live leak — the guard is simply blind to it. But the day someone adds
  # `counter([:stacks, :system, :rollback, …], tags: [:reason])` the guard would
  # PASS, because `:reason` is declared bounded and the declaration never said
  # for whom.
  #
  # That is this file's own thesis failing one level up: a justification a
  # machine cannot check is a sentence. So the exception is named, and the test
  # below refuses to let one of these events be registered with the key as a tag.
  @free_text_reason_emitters [
    {[:stacks, :system, :rollback], :reason,
     "operator-supplied rollback justification, read from a workflow input"}
  ]

  # Words that must never appear as a SEGMENT of a label key, whatever the
  # allowlist says. Either per-person (a disclosure) or per-record (unbounded
  # cardinality).
  #
  # Segment-exact, not substring: a substring check reads `:handler` as
  # containing "handle" and rejects a bounded module name, which trains the next
  # person to weaken the check rather than trust it. A guard that cries wolf
  # gets edited until it is quiet.
  @forbidden_segments ~w(
    handle email mail user title body query url uri path address addr ip
    phone token secret password isbn message id uuid
  )

  # Words that are per-person on one noun and harmless on another — a display
  # name versus a circuit-breaker name. A label containing one must say which it
  # is, here, rather than be guessed at either way.
  @ambiguous_segments ~w(name code)

  @ambiguous_label_notes %{
    fuse_name: "the circuit breaker's own atom, one per declared breaker — not anyone's name",
    name:
      "an OTP application name (prom_ex's Application plugin) or an Oban instance name — a " <>
        "module/atom from configuration, never a person. The key alone cannot say that, which " <>
        "is exactly why this map exists",
    database_name:
      "the database name from the repo's own configuration — constant per deploy, and " <>
        "infrastructure rather than anybody's name"
  }

  # ⚠️ EVERY registered plugin, derived from `Core.PromEx.plugins/0` — not just
  # the project's own.
  #
  # This read `StacksPlugin.event_metrics([])` and nothing else, under a
  # moduledoc describing "the metrics pipeline". `plugins/0` registers six:
  # Application, Beam, Phoenix, Ecto, Oban and Stacks. So five of six were
  # unchecked, and `MetricsPusher.push/1` POSTs `PromEx.get_metrics/1`
  # WHOLESALE — the audience map does not filter the push — so every one of
  # those labels reaches the store this guard's own moduledoc describes as
  # having no erasure path.
  #
  # Derived from `plugins/0` rather than listed, so registering a plugin extends
  # the guard automatically. That is the property that makes it outlive whoever
  # wrote it; a hand-listed roster is how it came to cover one of six.
  defp registered_metrics do
    Core.PromEx.plugins()
    |> Enum.flat_map(&plugin_metrics/1)
  end

  defp plugin_metrics({module, opts}), do: collect_metrics(module, opts)
  defp plugin_metrics(module), do: collect_metrics(module, [])

  defp collect_metrics(module, opts) do
    Code.ensure_loaded?(module)

    # `otp_app` is injected by PromEx itself when it initialises each plugin, so
    # it is absent from the `plugins/0` entries and the library's own
    # `Application` plugin fetches it with `Keyword.fetch!/2`. Supplying it here
    # is what makes this harvest see the same metrics the running pipeline
    # registers; without it the Application plugin raises
    # `KeyError: key :otp_app not found`.
    opts = Keyword.put_new(opts, :otp_app, :core)

    # All three PromEx metric kinds. A polling or manual metric's labels reach
    # the store exactly like an event metric's, so checking only `event_metrics`
    # would be a narrower version of the same mistake this change fixes.
    for kind <- [:event_metrics, :polling_metrics, :manual_metrics],
        function_exported?(module, kind, 1),
        group <- List.wrap(apply(module, kind, [opts])),
        metric <- group.metrics do
      metric
    end
  end

  defp labels_in_use do
    registered_metrics()
    |> Enum.flat_map(& &1.tags)
    |> Enum.uniq()
  end

  # The project's own metrics, separated from the library plugins' — because the
  # two are governed differently and conflating them would weaken both halves.
  #
  # A label on OUR metric is a choice we made at an emit site we control, so the
  # rule can be "declare why it is bounded, and a person-shaped name fails
  # outright". A label on a library plugin's metric is not ours to change: the
  # only levers are to stop registering the plugin or to accept it. Holding both
  # to the project rule would force blessing library labels into
  # `@bounded_labels`, which is exactly the "allowlist blesses a PII-shaped
  # name" failure this file's moduledoc warns against.
  #
  # So the project's labels keep the strict rule, and the library's get their own
  # declarations below with the risk stated rather than hidden.
  defp project_metrics do
    StacksPlugin.event_metrics([]) |> Enum.flat_map(& &1.metrics)
  end

  defp project_labels_in_use do
    project_metrics() |> Enum.flat_map(& &1.tags) |> Enum.uniq()
  end

  # Library-plugin labels whose value set IS bounded, each with where the bound
  # comes from. Verified by reading `deps/prom_ex`, not inferred from the name.
  @library_owned_labels %{
    action: "Phoenix route action — an atom from the router, bounded by the route table",
    author:
      "prom_ex reads $GIT_AUTHOR and falls back to the literal \"Git author not available\"; " <>
        "this project never sets that variable, so the value is one constant string. ⚠️ Setting " <>
        "GIT_AUTHOR would put a person's name in a store with no erasure path — do not set it",
    circuit_breaker: "Oban circuit-breaker name — one per configured breaker",
    command: "Ecto query command (:select/:insert/:update/:delete) — a closed set",
    controller: "Phoenix controller module — bounded by the router",
    database_host:
      "from the repo's own config, constant per deploy; infrastructure, not a person",
    database_name: "likewise from repo config, constant per deploy",
    error:
      "prom_ex tags Oban job errors with the exception MODULE, never its message, so this is " <>
        "bounded by the set of exception types rather than by their contents",
    event: "Phoenix channel event name; this app registers no channels, so the set is empty",
    host:
      "⚠️ NOT bounded — see @library_unbounded_labels. Listed here only so the stale-declaration " <>
        "check does not report it twice",
    kind: "Oban error kind (:error/:exit/:throw) — three values",
    method: "HTTP verb, bounded in practice by the fly-proxy in front of the app",
    modules:
      "a COUNT, not a list — prom_ex emits `length(Application.spec(app)[:modules])`, so one " <>
        "integer per dependency",
    name:
      "the OTP application or Oban instance name — see @ambiguous_label_notes, which is what " <>
        "this file requires for any label whose key could mean a person's name",
    path:
      "⚠️ NOT the request path, despite the key. prom_ex resolves it through " <>
        "`Phoenix.Router.route_info/4` and tags the matched ROUTE PATTERN (\"/api/books/:id\"), " <>
        "falling back to the literal \"Unknown\" when no route matches — so it is bounded by the " <>
        "router, and an unrouted path cannot mint a series. Read in deps/prom_ex rather than " <>
        "inferred from the name, because the name is exactly what would have made this look unsafe",
    node: "Erlang node name — one per running instance",
    plugins: "Oban's configured plugin list, from config; constant per deploy",
    port: "the endpoint's configured port — one constant",
    prefix: "Oban's schema prefix, from config; constant per deploy",
    queue: "Oban queue name — one per configured queue",
    queues: "Oban's configured queue list, from config; constant per deploy",
    sha:
      "prom_ex reads $GIT_SHA and falls back to \"Git SHA not available\"; this project never " <>
        "sets it, so the value is one constant string",
    state: "Oban job state (available/executing/completed/…) — a closed set",
    transport: "Phoenix channel transport; no channels are registered, so the set is empty",
    url: "the endpoint's configured URL — one constant",
    version: "a dependency's version string — one per dependency"
  }

  # ⚠️ Library labels that are genuinely NOT bounded, recorded rather than
  # blessed. Each entry says why it cannot be fixed at the emit site and what
  # would mitigate it. The count is pinned below so a new one cannot be added
  # quietly — this map is the one place in this file where a risk is accepted,
  # and it has to stay small enough to read.
  @library_unbounded_labels %{
    host:
      "prom_ex's Phoenix plugin tags HTTP metrics with `conn.host` — the raw Host header, " <>
        "chosen by the CLIENT. A caller sending a distinct Host per request mints one series " <>
        "per value, which is a cardinality attack on the metrics store rather than a PII leak " <>
        "(a hostname is not a person). Not fixable at the emit site: the plugin offers no " <>
        "per-tag filter, and dropping the plugin would lose the HTTP latency and request " <>
        "metrics entirely. Mitigation if it is ever exercised: reject unknown Hosts at the " <>
        "edge, or stop registering PromEx.Plugins.Phoenix and emit the three HTTP families " <>
        "from the project's own plugin with a bounded host label."
  }

  defp family(metric), do: Enum.join(metric.name, "_")

  # A metric's event name — the telemetry event it listens to, which is what
  # ties a registered metric back to the emit site that fills its metadata.
  defp metric_event(metric), do: Map.get(metric, :event_name, [])

  defp segments(tag), do: tag |> Atom.to_string() |> String.split("_")

  @repo_root Path.expand("../../../../..", __DIR__)

  # Every Elixir source under the app, read once. Deliberately `apps/core/lib`
  # only: a test that audits something is not a caller whose label reaches
  # production.
  defp all_sources do
    Path.wildcard(Path.join(@repo_root, "apps/core/lib/**/*.ex"))
    |> Enum.map(&{&1, File.read!(&1)})
  end

  # Each scan pattern with its OWN minimum count, rather than one aggregate
  # floor over all of them.
  #
  # **A floor is the pattern's OWN distinct count, counted independently of the
  # other patterns.** Stating the rule because getting it wrong is subtle: four
  # of these floors were the pattern's total, and pattern 1's was its UNIQUE
  # contribution — 14 rather than 15 — because `user.data_deleted` is matched by
  # both pattern 1 and pattern 3 (`Audit.log(nil, …)` in `gdpr/deletion.ex`
  # satisfies `\blog\(nil,` at the `.`→`l` boundary). A mixed basis left one
  # pattern with a slack of exactly one.
  #
  # Why one slack mattered: pattern 1 matches its first argument with `[^,]+`,
  # which cannot match an argument CONTAINING a comma — and
  # `Audit.log(Keyword.get(opts, :actor_id), @audit_action, …)` is standing
  # proof that shape occurs here. So the realistic degradation is not the
  # pattern dying (that gives 0 and flunks loudly) but one existing call site's
  # first argument gaining a comma: 15 drops to 14, the floor passes, and that
  # site's action silently stops being checked — through the pattern that covers
  # 15 of the 17 actions.
  #
  # ⚠️ The aggregate floor was calibrated to exactly the number that survived
  # its own newest pattern breaking. Patterns 1 and 2 supply 16 distinct
  # actions; pattern 3's only UNIQUE contribution is `system.rollback` (its
  # other match, `user.data_deleted`, is also caught by pattern 1). So with a
  # single `>= 16`, pattern 3 could stop matching, 16 would remain, the floor
  # would pass, and the subset check would silently stop covering the only
  # audit write inside `Stacks.Audit` — one of the four values this whole test
  # exists because of. A per-pattern floor also makes a dead pattern
  # diagnosable: one aggregate number cannot say WHICH scan died.
  # Regex SOURCES, not compiled sigils: a compiled `~r//` is a Reference and
  # cannot be escaped out of a module attribute into a function body.
  @action_patterns [
    {~S/Audit\.log\(\s*[^,]+,\s*"([a-z_.]+)"/, 15, "direct Audit.log/3 calls", :all},
    {~S/@audit_action\s+"([a-z_.]+)"/, 1, "@audit_action module attributes", :all},
    {~S/\blog\(nil,\s*"([a-z_.]+)"/, 2, "audit writes whose first argument is nil", :all}
  ]

  # ⚠️ The floor of 6 is itself a finding. Before scoping, this scan collected 7
  # — the seventh being `bookshelf`, whose ONLY occurrence in the tree is a
  # `VisibilityGrant` changeset in `social/social.ex`. Nothing audits a
  # bookshelf. So `"bookshelf"` sits in `@telemetry_resource_types` as dead
  # vocabulary: harmless, because the assertion is audited ⊆ declared and an
  # unused declared value simply never labels anything, but it was there giving
  # the unscoped scan a value to find. Left in place rather than removed — it
  # costs nothing and would be correct the day something does audit a shelf —
  # and recorded here because the scoped scan is what made it visible.
  # `resource_type:` is scoped to files that actually audit; see
  # `auditing_sources/0` for why. `def resource_type, do:` is the indirect
  # source for the data-correction modules, named here the way
  # @indirect_action_sites names the action equivalent.
  @resource_type_patterns [
    {~S/resource_type:\s*"([a-z_]+)"/, 6, "resource_type: options at audit sites", :auditing},
    {~S/def resource_type,\s*do:\s*"([a-z_]+)"/, 1, "data-correction resource_type/0 callbacks",
     :all}
  ]

  # Bare `log(` call sites inside `Stacks.Audit` itself — the internal-wrapper
  # shape `log_rollback/1` established.
  #
  # ⚠️ Declared separately because the main census counts `Audit.log(`, of which
  # `audit.ex` contains ZERO: its own writes are unqualified self-calls. So the
  # census's promise — a new site changes the count and fails — did not hold in
  # the one file that produced this defect in the first place. A natural next
  # wrapper (`log_admin_action(user_id, "deploy.promoted", …)`) would match none
  # of the three action patterns AND leave the `Audit.log(` count unmoved.
  # Counted test-side rather than fully qualifying the self-call in production:
  # production should not contort for a scanner.
  @internal_audit_log_sites 1

  # The number of `Audit.log(` call sites in apps/core/lib. Declared so that a
  # NEW one fails loudly and has to be classified, rather than being silently
  # missed by a literal scan that cannot parse nested call arguments.
  @audit_call_sites 16

  # The call sites whose action is not a string literal: {file, attribute,
  # the literal it resolves to}. Each is invisible to the literal scan, so each
  # is named here and checked to still resolve where it claims.
  @indirect_action_sites [
    {"apps/core/lib/stacks/data_correction.ex", "@audit_action", "data.correction.applied"}
  ]

  # Sources that actually write to the audit log — the only files whose
  # `resource_type:` options belong to the audit metric's vocabulary.
  #
  # ⚠️ Scoped because the unscoped scan over-collected and the risk ran the
  # over-strong way. `social/social.ex:565` sets `resource_type: "bookshelf"` on
  # a `VisibilityGrant` CHANGESET — nothing to do with auditing — and the test
  # passed only because `bookshelf` happened to already be in the vocabulary.
  # The next `resource_type: "whatever"` added to any changeset anywhere in
  # `apps/core/lib` would have reddened this test, whose cheapest fix would be
  # polluting the audit label vocabulary with an unrelated value. A guard that
  # cries wolf gets edited until it is quiet.
  #
  # `audit.ex` qualifies as an auditing source despite calling nothing: it IS
  # the writer, and contributes `"deploy"` and the `"unknown"` default.
  defp auditing_sources do
    for {path, source} <- all_sources(),
        String.contains?(source, "Audit.log(") or String.contains?(source, "@audit_action") or
          Path.basename(path) == "audit.ex",
        do: {path, source}
  end

  # A pattern with its own anti-vacuity floor. A scan that drops below its floor
  # FLUNKS naming itself, rather than contributing nothing to a subset check
  # that an empty list satisfies.
  defp scan_with_floor!({pattern, floor, description, scope}) do
    regex = Regex.compile!(pattern)
    sources = if scope == :auditing, do: auditing_sources(), else: all_sources()

    found =
      for {_path, source} <- sources,
          [_, captured] <- Regex.scan(regex, source),
          do: captured

    distinct = found |> Enum.uniq() |> Enum.sort()

    if length(distinct) < floor do
      flunk(
        "the scan for #{description} found #{length(distinct)} distinct value(s), below its " <>
          "declared floor of #{floor}. That pattern has stopped matching the code, so the " <>
          "subset assertion it feeds is now partly vacuous — re-point the pattern rather " <>
          "than lowering the floor.\nFound: #{inspect(distinct)}"
      )
    end

    found
  end

  describe "every label is bounded, by declaration" do
    test "a metric cannot attach a label that has not been declared bounded" do
      # ⚠️ Over EVERY registered plugin, and either declaration satisfies it.
      # This read one plugin of six, under a moduledoc describing "the metrics
      # pipeline"; the other five were unchecked while `MetricsPusher.push/1`
      # sent them to the store wholesale.
      declared = Map.merge(@bounded_labels, @library_owned_labels)

      undeclared =
        for metric <- registered_metrics(),
            tag <- metric.tags,
            not Map.has_key?(declared, tag),
            do: "#{family(metric)} → #{inspect(tag)}"

      assert undeclared == [],
             "these metrics attach a label that is not declared bounded in " <>
               "@bounded_labels or @library_owned_labels: " <>
               "#{inspect(Enum.uniq(undeclared))}. A label is a Prometheus dimension: " <>
               "one series per distinct value, forever. Add it WITH the reason its " <>
               "value set is bounded, or stop attaching it — and if the value can name " <>
               "a person, it must not be a label at all."
    end

    test "no stale declarations — every declared label is still attached by something" do
      # Otherwise the map accumulates reasons for labels nobody emits, and a
      # reader cannot tell which of them are load-bearing.
      in_use = MapSet.new(labels_in_use())

      stale =
        @bounded_labels
        |> Map.merge(@library_owned_labels)
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(in_use, &1))

      assert stale == [],
             "these labels are declared bounded but no metric attaches them: " <>
               inspect(Enum.sort(stale))
    end

    test "the accepted-risk map stays small and every entry is still attached" do
      # ⚠️ The ceiling on the one place this file accepts a risk instead of
      # failing. Without it, @library_unbounded_labels is where an inconvenient
      # finding goes to be forgotten — the allowlist-with-a-written-reason
      # failure the moduledoc describes, one map over.
      assert map_size(@library_unbounded_labels) <= 1,
             "@library_unbounded_labels has grown to #{map_size(@library_unbounded_labels)} " <>
               "entries. Each one is an unbounded Prometheus dimension this project has " <>
               "decided to live with; a growing list of those is a cardinality incident " <>
               "waiting for traffic. Raise this ceiling only with the mitigation written down."

      in_use = MapSet.new(labels_in_use())

      stale =
        @library_unbounded_labels
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(in_use, &1))

      assert stale == [],
             "these accepted risks describe labels nobody attaches any more, so the " <>
               "acceptance is obsolete: " <> inspect(stale)
    end
  end

  describe "the declaration cannot bless a label that names a person or a record" do
    test "no label in use has a per-person or per-record name" do
      # ⚠️ The PROJECT's labels only, and that is a deliberate narrowing rather
      # than a convenience. This rule's remedy is "emit the fact and leave the
      # identifier out", which is an instruction to whoever owns the emit site —
      # and for a library plugin nobody here owns it. Applied to all six
      # plugins, the rule's only available outcome is to bless the name in an
      # allowlist, which the moduledoc identifies as the way a guard stops
      # meaning anything.
      #
      # Library labels are not unchecked: they are declared in
      # `@library_owned_labels` with where their bound comes from, and the one
      # genuinely unbounded label is accepted explicitly, with a ceiling, in
      # `@library_unbounded_labels`. `:author` in particular was read rather
      # than assumed — prom_ex falls back to a constant string and this project
      # never sets $GIT_AUTHOR, so no name is emitted.
      offenders =
        for tag <- project_labels_in_use(),
            segment <- segments(tag),
            segment in @forbidden_segments,
            do: "#{inspect(tag)} (segment #{inspect(segment)})"

      assert offenders == [],
             "these labels are named like a person or a record: " <>
               "#{inspect(Enum.uniq(offenders))}. The metrics store has no erasure " <>
               "path, no consent gate, and for a public family an anonymous reader, " <>
               "so a value like this cannot be retracted once pushed. Emit the FACT " <>
               "and leave the identifier out: a count of handle changes, not the " <>
               "handle. Adding it to @bounded_labels does not make it safe and will " <>
               "not satisfy this test."
    end

    test "a label whose name is ambiguous has to say which sense it is" do
      unexplained =
        for tag <- labels_in_use(),
            segment <- segments(tag),
            segment in @ambiguous_segments,
            not Map.has_key?(@ambiguous_label_notes, tag),
            do: "#{inspect(tag)} (segment #{inspect(segment)})"

      assert unexplained == [],
             "these labels contain a word that is per-person on one noun and " <>
               "harmless on another: #{inspect(Enum.uniq(unexplained))}. Add an entry " <>
               "to @ambiguous_label_notes saying what the VALUE is — a template's own " <>
               "name is bounded, a reader's is a disclosure, and the key alone cannot " <>
               "tell them apart."
    end

    test "no stale ambiguity notes" do
      in_use = MapSet.new(labels_in_use())

      stale =
        @ambiguous_label_notes
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(in_use, &1))

      assert stale == [],
             "these ambiguity notes describe labels nobody attaches: " <> inspect(stale)
    end
  end

  describe "a declared-bounded label is bounded at its SOURCE" do
    # ⚠️ This describe exists because the declarations above were WRONG when
    # first written, in the file whose whole design is that a declaration cannot
    # be trusted on its own.
    #
    # `action` was declared "from the fixed set the audit writer accepts". The
    # writer accepts any string: its signature is `String.t()` and nothing
    # validated it, so both labels were bounded by caller discipline and by
    # nothing else. The reason read plausibly and was false — which is exactly
    # the defect this project has shipped before, in an allowlist whose written
    # justification nothing checked, and which `@forbidden_segments` above exists
    # to make impossible for the PII half.
    #
    # So the two labels whose boundedness lives in code rather than in a literal
    # get asserted here. This cannot be made general — "is this value bounded"
    # is a question about a specific producer — so it is a small set of named
    # checks that grows when a label's source is non-obvious.
    test "the audit label vocabularies exist and name real values" do
      # ⚠️ This used to assert the BEHAVIOUR here, through a public
      # `Audit.bounded_label_for/2` that existed only so this test could reach a
      # private function. That accessor is gone, and the behaviour is now
      # asserted where it actually happens: `gdpr_telemetry_test.exs` drives
      # `Audit.log/3` end to end and asserts both halves of the contract — an
      # unknown action arrives as `"other"` in the telemetry metadata while the
      # audit ROW keeps the caller's exact string — with a companion test
      # proving a KNOWN action passes through unchanged, so the bounding
      # assertion cannot be satisfied by a function that collapses everything.
      #
      # That is strictly stronger than a pass-through to a private function, and
      # it needed no new public promise on a context module. What remains here is
      # this file's own job: the `action` and `resource_type` entries in
      # @bounded_labels justify themselves by naming these two vocabularies, so
      # the vocabularies have to exist and be real. Their COMPLETENESS is the
      # sibling test below.
      actions = Stacks.Audit.telemetry_actions()
      resource_types = Stacks.Audit.telemetry_resource_types()

      assert "user.login" in actions,
             "the known-action vocabulary no longer contains a value @bounded_labels' reason " <>
               "for `action` depends on existing"

      assert "user" in resource_types, "the known-resource-type vocabulary looks wrong"

      assert "other" not in actions and "other" not in resource_types,
             "`other` is in a vocabulary, which would make the collapse value indistinguishable " <>
               "from a real action a caller passed"
    end

    test "every action and resource type actually audited is in the bounded set" do
      # ⚠️ The finding that produced this test: the sets were INCOMPLETE the day
      # they were written, and the comment above them claimed "Every caller today
      # passes a literal from the sets below". Four values were missing —
      # `admin.account_restored`, `data.correction.applied`, `book_edition`, and
      # `system.rollback`, which `Audit.log_rollback/1` emits forty lines below
      # the list in that same module. Each silently labelled `other`, so the
      # operator-attribution signal for someone reaching into a specific account
      # became indistinguishable from any unknown string.
      #
      # That is the same error the describe's own header is about, one level up:
      # the first version asserted a false REASON, this one asserted a false
      # POPULATION. The completeness of an allowlist is a fact about its
      # callers, so it has to be read off the callers.
      #
      # The remedy when this fails is to add the value to `@telemetry_actions`
      # in `Stacks.Audit` — not to delete the assertion. If an action genuinely
      # SHOULD aggregate under `other` because its values are high-cardinality
      # by nature, that is a deliberate choice and belongs in this test as a
      # named exception with its reason, so the next reader can tell a decision
      # from an oversight.
      actions = Enum.flat_map(@action_patterns, &scan_with_floor!/1)
      resource_types = Enum.flat_map(@resource_type_patterns, &scan_with_floor!/1)

      unbounded_actions =
        actions
        |> Enum.uniq()
        |> Enum.reject(&(&1 in Stacks.Audit.telemetry_actions()))
        |> Enum.sort()

      unbounded_types =
        resource_types
        |> Enum.uniq()
        |> Enum.reject(&(&1 in Stacks.Audit.telemetry_resource_types()))
        |> Enum.sort()

      assert unbounded_actions == [],
             "these actions are audited somewhere in apps/core/lib and are NOT in " <>
               "Audit.telemetry_actions/0, so each one labels as `other` and its metric " <>
               "series is indistinguishable from an unknown value: " <>
               "#{inspect(unbounded_actions)}"

      assert unbounded_types == [],
             "these resource types are audited and are NOT in " <>
               "Audit.telemetry_resource_types/0, so each labels as `other`: " <>
               "#{inspect(unbounded_types)}"
    end

    test "every audit call site is accounted for, so the scan above cannot miss one" do
      # ⚠️ This test exists because my FIRST attempt at it was vacuous, which is
      # worth recording where the fix lives.
      #
      # It tried to regex the second argument of every `Audit.log(` call and
      # flag any that was not a string literal. Two things were wrong. The
      # comprehension filtered on `[line] <- Regex.scan(...)` while the pattern
      # had a capture group, so every scan result was a two-element list, the
      # filter matched nothing, and the assertion compared [] to [] forever.
      # And even corrected it could not have worked: `data_correction.ex` calls
      # `Audit.log(Keyword.get(opts, :actor_id), @audit_action, …)`, whose first
      # argument contains a comma, and a regex cannot reliably find the second
      # argument of a call whose first one has nested parens and commas.
      #
      # So this does not parse arguments at all. It counts CALL SITES and
      # requires the total to match a declared number. A new site — literal or
      # not — changes the count and fails here, and whoever added it has to come
      # and say which kind it is. That is fail-closed without pretending regex
      # can parse Elixir.
      sites =
        for {path, source} <- all_sources(),
            count = length(Regex.scan(~r/Audit\.log\(/, source)),
            count > 0,
            do: {Path.relative_to(path, @repo_root), count}

      total = sites |> Enum.map(&elem(&1, 1)) |> Enum.sum()

      assert total == @audit_call_sites,
             "the number of `Audit.log(` call sites in apps/core/lib is #{total}, not the " <>
               "declared #{@audit_call_sites}. If you ADDED one: check that its action is in " <>
               "`Audit.telemetry_actions/0` (the sibling test will tell you), then update " <>
               "@audit_call_sites. If its action is not a string literal, add it to " <>
               "@indirect_action_sites with the literal it resolves to, because the sibling " <>
               "test's scan cannot see it.\n\nSites found:\n" <>
               (sites |> Enum.sort() |> Enum.map_join("\n", fn {f, n} -> "  #{n}x #{f}" end))

      # ⚠️ The second census, scoped to `audit.ex`, because the count above is of
      # `Audit.log(` and that file contains none — its own writes are
      # unqualified self-calls, so the promise "a new site changes the count"
      # did not hold in the one file that produced this defect.
      internal =
        ~r/^\s*(?:case )?log\(/m
        |> Regex.scan(File.read!(Path.join(@repo_root, "apps/core/lib/stacks/audit.ex")))
        |> length()

      assert internal == @internal_audit_log_sites,
             "`Stacks.Audit` now has #{internal} internal `log(` call site(s), not the " <>
               "declared #{@internal_audit_log_sites}. These are invisible to the " <>
               "`Audit.log(` census above. If you added an internal wrapper like " <>
               "`log_admin_action(user_id, \"deploy.promoted\", …)`, note that it matches " <>
               "none of @action_patterns either — add a pattern for its shape, then update " <>
               "this count."

      # The one call site whose action is not a literal, named so the sibling
      # scan's blind spot is explicit rather than unknown. Its value IS covered,
      # via the `@audit_action "…"` pattern that reads the attribute's own
      # definition.
      for {file, attribute, resolves_to} <- @indirect_action_sites do
        source = File.read!(Path.join(@repo_root, file))

        assert source =~ "Audit.log(" and source =~ attribute,
               "#{file} no longer calls Audit.log with #{attribute}, so this entry in " <>
                 "@indirect_action_sites is stale — remove it or re-point it"

        assert source =~ ~s(#{attribute} "#{resolves_to}"),
               "#{file}'s #{attribute} no longer resolves to #{inspect(resolves_to)}, so the " <>
                 "sibling scan is now collecting a value this site does not emit"

        assert resolves_to in Stacks.Audit.telemetry_actions(),
               "#{inspect(resolves_to)} is emitted via #{attribute} and is not bounded"
      end
    end

    test "the invite-gate label is total, so an unexpected refusal cannot raise" do
      # Reached from an UNAUTHENTICATED registration path. Its sibling status
      # function is total; this one was not, and the gate module already defines
      # a seventh refusal atom one `with` clause away from reaching it. A
      # `FunctionClauseError` there is a 500 on registration — both the worst
      # place for one and a distinguishable response on an endpoint designed to
      # tell a prober nothing.
      assert StacksWeb.AuthController.invite_label_for(:invite_expired) == :expired

      # NOT `:invite_not_found` as an example of something that can arrive here.
      # It cannot: it is produced only by `Invites.check/1`, consumed only by
      # `InviteController`, which answers 404 and never reaches this controller.
      # An earlier version of this assertion and the comment beside the function
      # both claimed it was "one `with` clause away" — plausible, unchecked and
      # false, which is this file's own failure mode a fourth time.
      #
      # The real reason the catch-all is load-bearing is wider: `do_register/3`
      # ends in `{:error, _, reason, _} -> {:error, reason}`, a pass-through over
      # EVERY step of the registration Multi. So the input set is any atom any
      # step returns, present or future — not the invite gate's vocabulary.
      assert StacksWeb.AuthController.invite_label_for(:a_future_multi_step_failure) == :other,
             "an atom from some other step of the registration Multi has no clause and no " <>
               "catch-all, so it would raise a FunctionClauseError on an unauthenticated " <>
               "registration path"

      assert StacksWeb.AuthController.invite_label_for(:something_nobody_has_added_yet) == :other
    end
  end

  describe "a free-text metadata key is never promoted to a label" do
    test "no registered metric tags an event whose metadata key is operator free text" do
      # The assertion the registry-scoped guard above cannot make for itself.
      # It checks every DECLARED label; this checks the one thing a declaration
      # cannot express — that a specific producer's value is not bounded, so
      # that producer's event must not carry the key as a tag however bounded
      # the key is elsewhere.
      offenders =
        for {event, key, why} <- @free_text_reason_emitters,
            metric <- registered_metrics(),
            metric_event(metric) == event,
            key in metric.tags,
            do: "#{family(metric)} tags #{inspect(key)} (#{why})"

      assert offenders == [],
             "a metric now attaches a metadata key that its emit site fills with free text: " <>
               "#{inspect(offenders)}. One series per distinct value, forever, in a store " <>
               "with no erasure path — and for an operator-written justification, the text " <>
               "itself may name a person. If the value has since been bounded at the emit " <>
               "site, remove the entry from @free_text_reason_emitters and say so there."
    end

    test "every named free-text emitter still exists and still carries its key" do
      # Anti-vacuity: the test above iterates @free_text_reason_emitters and
      # passes trivially if an entry has gone stale, which is exactly when
      # someone has been editing the emit site.
      sources = all_sources()

      for {event, key, _why} <- @free_text_reason_emitters do
        event_literal = "[" <> Enum.map_join(event, ", ", &inspect/1) <> "]"

        emitting =
          Enum.filter(sources, fn {_p, src} ->
            String.contains?(src, ":telemetry.execute(#{event_literal}")
          end)

        assert emitting != [],
               "no source emits #{event_literal} any more, so its entry in " <>
                 "@free_text_reason_emitters is stale. Remove it, or re-point it at the " <>
                 "event that replaced it — leaving it makes the sibling test vacuous."

        assert Enum.any?(emitting, fn {_p, src} -> src =~ "#{key}:" end),
               "#{event_literal} is emitted but no longer puts #{inspect(key)} in its " <>
                 "metadata. If the free text is gone, drop the entry and record why."
      end
    end
  end

  describe "label counts stay small enough to reason about" do
    test "no metric carries more than three labels" do
      # Series count is the PRODUCT of the label value sets, so each extra
      # dimension multiplies. Three is the most any metric here needs, and a
      # fourth should have to argue for itself rather than arrive quietly.
      #
      # ⚠️ The PROJECT's metrics only. The library plugins' metrics carry up to
      # six tags each — prom_ex's Phoenix HTTP families alone use status,
      # method, path, controller, action and host — and that is a choice made in
      # a dependency, not here. Applying this budget to them would leave one
      # remedy: raise the number until it stops firing, which deletes the rule
      # for the metrics it was actually written to govern.
      #
      # Their dimensionality is not unexamined; it is where the `:host` risk in
      # @library_unbounded_labels comes from, recorded with its mitigation.
      wide =
        for metric <- project_metrics(),
            length(metric.tags) > 3,
            do: "#{family(metric)} (#{length(metric.tags)} labels)"

      assert wide == [],
             "these metrics carry more than three labels, and series count is the " <>
               "product of the value sets: #{inspect(wide)}"
    end
  end
end
