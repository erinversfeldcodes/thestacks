defmodule Stacks.UserAgent do
  @moduledoc """
      Whether a client enforces the `SameSite` cookie attribute.

      ⛔ WHY THIS EXISTS, AND WHY IT IS A CLASSIFIER RATHER THAN A LOG LINE.

      A decision is pending on whether a double-submit CSRF token is worth a
      77-call-site refactor plus an enforcement step that can reject writes. For
      every non-GET method `SameSite=Lax` already blocks the session cookie
      cross-site, and the one hole Lax leaves — top-level GET navigation — has no
      state-changing target (measured: all 23 session-authorised GET routes are
      reads). So the residual threat a token closes is principally **clients that
      ignore SameSite**, and the size of that population is a measurement rather
      than a judgement.

      ⚠️ **Measured 2026-10-23: nothing in this application records an inbound
      `User-Agent`.** Not the request log (Phoenix does not log it), not
      `audit.audit_log` (no such column), and the metrics plugin explicitly
      declines to tag by it — "a per-crawler label would be an unbounded
      user-agent string". So the question could not be answered from existing
      data by anyone.

      ## ⛔ A BOUNDED CLASSIFICATION, NOT A STORED STRING

      This returns one of three atoms and **nothing retains the user agent**. The
      string is read from the connection, classified in memory, and discarded.

      That is the difference between answering the question and starting to
      collect browser fingerprints: a three-valued counter is not personal data,
      where a retained `User-Agent` string arguably is under the project's own
      4-tier classification. The same move `Stacks.Audit` makes for metric labels
      and `Stacks.Accounts.Invites` makes for telemetry labels — bound it at the
      emit site, beside the atoms it maps.

      ## ⚠️ The classifier is DELIBERATELY CRUDE, and `:unknown` is load-bearing

      User-agent parsing is unreliable and this does not try to be a library. It
      recognises the four families whose SameSite floor is documented and sends
      everything else to `:unknown`.

      ⚖️ **That makes the measurement honest rather than weak.** A large
      `:unknown` bucket is itself the finding — it says the classifier cannot
      answer for that traffic, which is information, where a classifier guessing
      `:enforces` for anything it did not recognise would answer the question
      with its own default and look confident doing it.

      Floors, from the browsers' own release notes:

        * Chrome / Chromium 51
        * Firefox 60
        * Safari 12 (and iOS Safari 12)
        * Edge 16

      Internet Explorer is classified `:does_not_enforce` at every version: it
      ignores the attribute entirely.
  """

  @type support :: :enforces | :does_not_enforce | :unknown

  # ⚠️ Order matters. Chrome's UA contains "Safari", Edge's contains both
  # "Chrome" and "Safari", and Chromium-based browsers advertise "Chrome" — so
  # the most specific family must be tested first or every Edge request is
  # counted as Chrome. Measured against real UA strings in the test file.
  # ⚠️ A function rather than a module attribute: a compiled `Regex` cannot be
  # escaped into an attribute in Elixir 1.18 (it is a reference, not a literal),
  # and the compiler refuses rather than silently recompiling per call.
  defp families do
    [
      {:edge, ~r/\bEdge?\/(\d+)/, 16},
      {:chrome, ~r/\bChrome\/(\d+)/, 51},
      {:firefox, ~r/\bFirefox\/(\d+)/, 60},
      {:safari, ~r/\bVersion\/(\d+).*\bSafari\b/, 12}
    ]
  end

  defp internet_explorer, do: ~r/\bMSIE\b|\bTrident\//

  @doc """
      Classifies a `User-Agent` string's SameSite enforcement.

      Returns `:enforces`, `:does_not_enforce`, or `:unknown`.

      ⛔ `:unknown` is the answer for anything unrecognised, INCLUDING a missing
      or empty header. It is never `:enforces` by default — a classifier that
      assumes enforcement for traffic it cannot identify answers the question
      with its own default, which is precisely the number this is being asked to
      produce.
  """
  @spec samesite_support(String.t() | nil) :: support()
  def samesite_support(nil), do: :unknown
  def samesite_support(""), do: :unknown

  def samesite_support(ua) when is_binary(ua) do
    if Regex.match?(internet_explorer(), ua) do
      :does_not_enforce
    else
      classify(ua)
    end
  end

  def samesite_support(_), do: :unknown

  defp classify(ua) do
    case Enum.find_value(families(), &match_family(&1, ua)) do
      {version, floor} when version >= floor -> :enforces
      {_version, _floor} -> :does_not_enforce
      nil -> :unknown
    end
  end

  # Returns `{version, floor}` for the first family whose pattern matches with a
  # parseable version, or `nil`.
  #
  # ⚠️ A family that matches with an UNPARSEABLE version returns `nil`, which
  # falls through to `:unknown` rather than to a guess. "Chrome/abc" is a client
  # we cannot place, and placing it anyway is the default-answering failure the
  # moduledoc is about.
  defp match_family({_family, pattern, floor}, ua) do
    with [_, version] <- Regex.run(pattern, ua) || :no_match,
         {n, _} <- Integer.parse(version) do
      {n, floor}
    else
      _ -> nil
    end
  end
end
