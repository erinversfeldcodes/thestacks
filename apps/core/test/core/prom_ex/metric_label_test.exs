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
  """
  use ExUnit.Case, async: true

  alias Core.PromEx.Plugins.Stacks, as: StacksPlugin

  # Every label key any registered metric attaches, and why its value set is
  # bounded. The reason is the point: it names where the boundedness comes from,
  # so the next person can check it rather than trust it.
  @bounded_labels %{
    action: "audit action verb, from the fixed set the audit writer accepts",
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
    reason: "bounded failure-reason atom, never a message or an exception",
    reason_class: "transport failure CLASS, deliberately a name rather than the failure",
    repo: "Ecto repo module name — the app declares two",
    resource_type: "domain resource kind, from the audit/visibility vocabulary",
    result: "ok / error style result atom",
    route_group: "coarse route family assigned by a plug, not a request path",
    source: "provenance tag, from a fixed set per emit site",
    status: "HTTP status code — bounded by the protocol",
    template: "email template name, one per declared template",
    tier: "age-gate tier — a small closed ladder",
    type: "bounded login-failure type atom",
    worker: "Oban worker module name — bounded by the worker set"
  }

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
    fuse_name: "the circuit breaker's own atom, one per declared breaker — not anyone's name"
  }

  defp registered_metrics do
    StacksPlugin.event_metrics([]) |> Enum.flat_map(& &1.metrics)
  end

  defp labels_in_use do
    registered_metrics()
    |> Enum.flat_map(& &1.tags)
    |> Enum.uniq()
  end

  defp family(metric), do: Enum.join(metric.name, "_")

  defp segments(tag), do: tag |> Atom.to_string() |> String.split("_")

  describe "every label is bounded, by declaration" do
    test "a metric cannot attach a label that has not been declared bounded" do
      undeclared =
        for metric <- registered_metrics(),
            tag <- metric.tags,
            not Map.has_key?(@bounded_labels, tag),
            do: "#{family(metric)} → #{inspect(tag)}"

      assert undeclared == [],
             "these metrics attach a label that is not declared bounded in " <>
               "@bounded_labels: #{inspect(Enum.uniq(undeclared))}. A label is a " <>
               "Prometheus dimension: one series per distinct value, forever. Add it " <>
               "WITH the reason its value set is bounded, or stop attaching it — and " <>
               "if the value can name a person, it must not be a label at all."
    end

    test "no stale declarations — every declared label is still attached by something" do
      # Otherwise the map accumulates reasons for labels nobody emits, and a
      # reader cannot tell which of them are load-bearing.
      in_use = MapSet.new(labels_in_use())

      stale =
        @bounded_labels
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(in_use, &1))

      assert stale == [],
             "these labels are declared bounded but no metric attaches them: " <>
               inspect(Enum.sort(stale))
    end
  end

  describe "the declaration cannot bless a label that names a person or a record" do
    test "no label in use has a per-person or per-record name" do
      offenders =
        for tag <- labels_in_use(),
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

  describe "label counts stay small enough to reason about" do
    test "no metric carries more than three labels" do
      # Series count is the PRODUCT of the label value sets, so each extra
      # dimension multiplies. Three is the most any metric here needs, and a
      # fourth should have to argue for itself rather than arrive quietly.
      wide =
        for metric <- registered_metrics(),
            length(metric.tags) > 3,
            do: "#{family(metric)} (#{length(metric.tags)} labels)"

      assert wide == [],
             "these metrics carry more than three labels, and series count is the " <>
               "product of the value sets: #{inspect(wide)}"
    end
  end
end
