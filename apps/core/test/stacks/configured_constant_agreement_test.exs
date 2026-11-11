defmodule Stacks.ConfiguredConstantAgreementTest do
  @moduledoc """
      Four places where one number is derived from another, and the derivation is
      the whole invariant.

      They are one module because they share a failure mode, not a subject: each
      is a pair of values that must agree, where both halves are individually
      correct and nothing notices when they stop corresponding. A duplicated
      constant does not fail loudly — it serves a stale answer, or in the worst
      case here a security window 86,400 times shorter than configured.

      ## Why the first two exist, specifically

      `Stacks.Duration`'s own moduledoc records the incident: three call sites
      each had a private `unit_in_seconds/1`, two with comments promising they
      mirrored each other, and the third handled only second/minute/hour — so a
      `{1, :day}` rotation grace fell through to its catch-all and was honoured
      as ONE SECOND. The converter was then centralised and `duration_test.exs`
      covers it thoroughly.

      What nothing covered is that the rotation grace still *goes through* it.
      `duration_test.exs` tests the converter in isolation; re-inlining a private
      unit table in `Accounts` would restore the original defect with every
      duration test still green. That is the gap these two close: one drives the
      grace behaviourally at a day-scale unit, the other refuses the shape the
      defect had.
  """
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts
  alias Stacks.Accounts.AuthTokenFamily
  alias Stacks.Email.Templates
  alias Stacks.Shelving

  @repo_root Path.expand("../../../..", __DIR__)

  describe "a configured duration honours its unit" do
    setup do
      original = Application.get_env(:core, :session_rotation_grace)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:core, :session_rotation_grace)
          value -> Application.put_env(:core, :session_rotation_grace, value)
        end
      end)

      :ok
    end

    test "a {1, :day} rotation grace accepts a token rotated two hours ago" do
      # The behavioural half. Two hours is inside a day and far outside the 20
      # seconds configured by default, so this passes only if the `:day` unit is
      # actually converted. Under the original defect — `{1, :day}` honoured as
      # one second — the two-hour-old token is treated as reuse, the whole family
      # is revoked, and the assertion below fails with :token_reuse_detected.
      Application.put_env(:core, :session_rotation_grace, {1, :day})

      user = insert(:user)
      fid = Ecto.UUID.generate()
      rotated_at = DateTime.add(DateTime.utc_now(), -2 * 60 * 60, :second)

      {:ok, _family} =
        Accounts.rotate_token_family(%{
          family_id: fid,
          user_id: user.id,
          current_jti: "jti-current",
          previous_jti: "jti-previous",
          rotated_at: rotated_at,
          session_started_at: rotated_at
        })

      assert :ok = Accounts.check_token_family(fid, "jti-current", to_string(user.id)),
             "precondition: the family's CURRENT token must authenticate, or the grace " <>
               "assertion below is not testing the grace path"

      assert :ok = Accounts.check_token_family(fid, "jti-previous", to_string(user.id)),
             "a token rotated two hours ago was refused under a {1, :day} grace window. " <>
               "The configured unit is not being converted — this is the 86,400x error " <>
               "Stacks.Duration was created to end, back in a different module."

      refute Core.Repo.get(AuthTokenFamily, fid).revoked_at,
             "the family was revoked as token reuse despite the token being inside the " <>
               "configured grace window, so every other session of this user died too"
    end

    test "a {1, :second} rotation grace rejects a token rotated two hours ago" do
      # The other direction, and the reason the test above is not satisfied by a
      # function that ignores its configuration and always returns a large
      # number. Same fixture, same age, opposite verdict — so the pair together
      # pin that the value is READ, not merely present.
      Application.put_env(:core, :session_rotation_grace, {1, :second})

      user = insert(:user)
      fid = Ecto.UUID.generate()
      rotated_at = DateTime.add(DateTime.utc_now(), -2 * 60 * 60, :second)

      {:ok, _family} =
        Accounts.rotate_token_family(%{
          family_id: fid,
          user_id: user.id,
          current_jti: "jti-current",
          previous_jti: "jti-previous",
          rotated_at: rotated_at,
          session_started_at: rotated_at
        })

      assert {:error, :token_reuse_detected} =
               Accounts.check_token_family(fid, "jti-previous", to_string(user.id)),
             "a two-hour-old token was accepted under a {1, :second} grace window, so the " <>
               "configured duration is not being read at all"
    end

    test "Accounts has no private unit table of its own" do
      # The structural half, and the one that refuses the defect's actual shape.
      # The behavioural tests above would also catch a re-inlined table that got
      # `:day` wrong — but only if it got `:day` wrong. A re-inlined table that
      # handles day and misses `:week` passes them and reintroduces exactly the
      # original bug for a unit nobody tested.
      source = File.read!(Path.join(@repo_root, "apps/core/lib/stacks/accounts.ex"))

      refute source =~ "defp unit_in_seconds",
             "Accounts has grown its own unit-to-seconds table again. This is the precise " <>
               "shape of the defect that made a {1, :day} session-rotation grace last one " <>
               "second: three private copies, two of them commented as mirroring each " <>
               "other. Call Stacks.Duration.to_seconds/1."

      assert source =~ "Duration.to_seconds(",
             "Accounts no longer routes a configured duration through Stacks.Duration, so " <>
               "the centralisation that fixed the 86,400x error has been undone somewhere " <>
               "in this module."
    end
  end

  describe "a number quoted to the reader equals the number enforced" do
    test "the confirmation email states the real unverified-account TTL" do
      # The template divides the TTL by 3600 rather than restating it, which is
      # correct today. What this catches is someone writing the number into the
      # copy — the obvious edit when the sentence reads awkwardly — after which
      # changing the TTL silently makes the email lie to every new reader.
      #
      # The TTL is a compile-time module attribute, so this cannot vary it and
      # re-render; it asserts correspondence at the current value instead.
      #
      # ⚠️ That has a consequence worth stating, because probing it is what
      # revealed it: the TTL is 24 hours, so hardcoding the literal "24 hours"
      # into the copy is byte-identical to the derived output and this test
      # passes. My first probe did exactly that and stayed green — the probe was
      # a no-op, not the test weak. What the test does hold is the pair: move the
      # TTL to 48h with the copy hardcoded and it fails, naming both numbers.
      # So it cannot catch a hardcode while the hardcode is still TRUE, which is
      # the right boundary — a correct hardcode is a latent defect, and this
      # fires the moment it becomes a real one.
      expected_hours = div(Accounts.unverified_account_ttl_seconds(), 3600)

      html = Templates.registration_confirmation("https://example.test/confirm/abc")

      assert html =~ "expires in #{expected_hours} hours",
             "the confirmation email does not quote the real unverified-account TTL " <>
               "(#{expected_hours} hours, from Accounts.unverified_account_ttl_seconds/0). " <>
               "A reader told the wrong window either loses an account they thought they " <>
               "had time to confirm, or waits past a link that already died."

      refute expected_hours == 0,
             "precondition: the TTL rounds to zero hours, so the assertion above is " <>
               "matching on a sentence that reads 'expires in 0 hours' and proves nothing"
    end

    test "the reset email's hardcoded expiry equals the token's max_age" do
      # ⚠️ This is the half of the describe that can actually drift, and it was
      # missing. A reviewer put it precisely: the structural assertion went where
      # behaviour already reached (`defp unit_in_seconds`, where the behavioural
      # pair above already covers the main case) and was omitted where behaviour
      # cannot reach at all.
      #
      # The registration template DERIVES its number from
      # `unverified_account_ttl_seconds/0`, so it cannot disagree — that is the
      # test above. The reset template HARDCODES "This link expires in 24
      # hours" while `Email.reset_password/2` enforces `max_age: 86_400` in a
      # different file. Two independent literals, no derivation between them.
      # They agree today, which is why this is a guard rather than a bug report.
      #
      # A source assertion, and unavoidably so: no behavioural test can observe
      # the relationship between a sentence baked into an HTML heredoc and a
      # `max_age` passed to `Phoenix.Token.verify/4`. Note also that
      # `expiry_phrase/1` already exists in that module and is not used here —
      # deriving the phrase would delete the need for this test, which is the
      # better fix whenever someone next touches that template.
      templates =
        File.read!(Path.join(@repo_root, "apps/core/lib/stacks/email/templates.ex"))

      email = File.read!(Path.join(@repo_root, "apps/core/lib/stacks/email.ex"))

      # Matches only the HARDCODED phrase: the derived sibling renders as
      # `expires in #{expiry_hours} hours`, which has no digits to capture.
      quoted_hours =
        single_integer!(
          templates,
          ~r/This link expires in (\d+) hours/,
          "the hardcoded expiry phrase in the password-reset email template"
        )

      enforced_seconds =
        single_integer!(
          email,
          ~r/"password_reset",\s*token,\s*max_age:\s*([\d_]+)/,
          "the max_age enforced for a password-reset token"
        )

      assert quoted_hours * 3600 == enforced_seconds,
             "the password-reset email tells the reader the link lasts " <>
               "#{quoted_hours} hours (#{quoted_hours * 3600}s) while the token is verified " <>
               "with max_age: #{enforced_seconds}s. One of the two literals moved without " <>
               "the other. A reader told the wrong window either loses an account they " <>
               "thought they had time to recover, or sits on a link that is already dead."
    end
  end

  describe "a cap enforced in one place is defined in one place" do
    test "the reading-pile limit has a single definition and a public accessor" do
      source = File.read!(Path.join(@repo_root, "apps/core/lib/stacks/shelving.ex"))

      definitions =
        source
        |> String.split("\n")
        |> Enum.filter(&String.match?(&1, ~r/^\s*@reading_pile_limit\s+\d+/))

      assert length(definitions) == 1,
             "the reading-pile cap is defined #{length(definitions)} times in shelving.ex: " <>
               "#{inspect(definitions)}. Two definitions of a cap is two caps."

      assert is_integer(Shelving.reading_pile_limit()) and Shelving.reading_pile_limit() > 0,
             "Shelving.reading_pile_limit/0 no longer returns the cap. It exists so that " <>
               "anything needing the number — a serializer, a client payload, a doc string " <>
               "— can ask for it instead of writing it down again."

      # Deliberately NOT a scan for the literal across lib/ and frontend/src.
      # The cap is 50, and `frontend/src/Page/Bookshelf/Helpers.elm` alone holds
      # four rows of page-width data in the same range — a bare-number scan
      # names those as defects. Asserting over a population without looking at
      # it is how three over-strong assertions got written in this sitting.
      # The single-definition property plus a public accessor is the part that
      # is both true and checkable; whether a client re-derives the cap is
      # recorded in the roadmap as wanting a different instrument.
    end
  end

  describe "a cache cannot evict an entry a reader would still accept" do
    test "the eviction cutoff is older than the longest TTL any caller passes" do
      # `Transparency.Cache.get/2` takes the TTL per call rather than holding
      # one, so "the longest TTL in use" is a property of the callers, not of
      # the cache. Today there is exactly one caller and it passes 45s, while
      # the sweep evicts at 10 minutes — a wide margin, and the assertion is
      # that the margin has the right SIGN, not that it is wide.
      #
      # Both numbers are read from source because the cutoff is an inline
      # literal in `handle_info(:cleanup, …)` with no name. Naming it would
      # make this assertion cleaner and is worth doing; it is a production
      # change this test does not need in order to hold the invariant.
      cache_source =
        File.read!(Path.join(@repo_root, "apps/core/lib/stacks/transparency/cache.ex"))

      transparency_source =
        File.read!(Path.join(@repo_root, "apps/core/lib/stacks/transparency.ex"))

      cutoff_ms =
        single_integer!(
          cache_source,
          ~r/cutoff\s*=\s*System\.monotonic_time\(:millisecond\)\s*-\s*([\d_]+)/,
          "the cleanup cutoff in transparency/cache.ex"
        )

      ttl_seconds =
        single_integer!(
          transparency_source,
          ~r/@cache_ttl_seconds\s+([\d_]+)/,
          "@cache_ttl_seconds in transparency.ex"
        )

      ttl_ms = ttl_seconds * 1_000

      assert cutoff_ms > ttl_ms,
             "the transparency cache evicts entries after #{cutoff_ms}ms while a reader " <>
               "still accepts them for #{ttl_ms}ms, so a fresh entry can be swept out from " <>
               "under a caller that would have used it. Every eviction in that window is a " <>
               "recomputation of the live signals — the thing the cache exists to avoid."

      assert ttl_ms > 0,
             "precondition: the TTL parsed as zero, which would make the comparison above " <>
               "trivially true"
    end
  end

  # Parses exactly one integer out of a source file, failing loudly when the
  # shape it depends on has moved. A regex that silently stops matching turns
  # every assertion built on it green, which is the failure mode this project
  # has shipped before — so a miss is a flunk, never a default.
  defp single_integer!(source, regex, description) do
    case Regex.run(regex, source) do
      [_, digits] ->
        digits |> String.replace("_", "") |> String.to_integer()

      nil ->
        flunk(
          "could not read #{description}. The code's shape has changed, so this test is no " <>
            "longer checking the invariant it names — re-point the pattern rather than " <>
            "deleting the assertion."
        )
    end
  end
end
