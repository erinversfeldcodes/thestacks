defmodule Stacks.ProbeCredentialShapeTest do
  @moduledoc """
      A fuse probe must exercise the credentials its production caller uses.

      A circuit breaker's probe decides when a blown fuse closes again, so a
      probe that does not carry production's auth is worse than no probe: it
      reports the dependency healthy while every production request 401s, and
      the fuse closes into a wall. The inverse is just as bad — a probe
      demanding a credential production does not send keeps a working
      dependency fused out.

      `circuit_breakers.ex` states this in prose at each probe ("Probe-auth
      audit: matches production — the same X-Subscription-Token header
      production searches send"). It holds today for all four credentialed
      probes. Nothing checked it, and the thing it guards against is a
      production auth rotation that the probe does not follow — which is
      invisible until the next outage, because the probe keeps passing.

      ## What this deliberately does NOT assert

      Not full header-list equality. Production Brave searches send
      `Accept-Encoding: gzip` and production Together requests send
      `content-type: application/json`; the probes correctly send neither (one
      is a transport preference, the other describes a POST body the probe's GET
      does not have). An equality assertion over the whole list fails against
      perfectly correct code and names two non-defects — the shape of
      over-strong assertion this project has shipped repeatedly.

      The credential is the part that must match. These assert exactly that: the
      same config key, the same credential header name, and a refusal to probe
      at all when the key is absent.
  """
  use ExUnit.Case, async: true

  alias Stacks.CircuitBreakers

  @repo_root Path.expand("../../../..", __DIR__)

  # Each credentialed probe and the production client it stands in for.
  #
  # `:config_key` is the literal as it appears in BOTH sources; `:header` is the
  # credential header name. `google_books` and `resend` are absent on purpose
  # and explained below.
  @credentialed_pairs [
    %{
      fuse: :brave_fuse,
      probe: :probe_brave,
      production: "apps/core/lib/stacks/discovery/brave_client.ex",
      config_key: ":brave_search_api_key",
      header: "X-Subscription-Token"
    },
    %{
      fuse: :together_ai_fuse,
      probe: :probe_together_ai,
      production: "apps/core/lib/stacks/ai/together_client.ex",
      config_key: ":vision_together_api_key",
      header: "authorization"
    }
  ]

  defp breakers_source do
    File.read!(Path.join(@repo_root, "apps/core/lib/stacks/circuit_breakers.ex"))
  end

  # The probe function's body, so a config key mentioned by a DIFFERENT probe in
  # the same (large) module cannot satisfy an assertion about this one.
  defp probe_body(source, probe_name) do
    case String.split(source, "def #{probe_name} do") do
      [_, rest | _] -> rest |> String.split("\n  end") |> List.first()
      _ -> nil
    end
  end

  test "every credentialed pair in this test's table actually exists" do
    # Anti-vacuity. Every assertion below iterates the table, so a trimmed
    # table silently narrows what this file covers. The count is pinned rather
    # than merely checked non-empty: dropping one pair is the plausible edit
    # (it fails, someone removes it), and a non-empty check would wave that
    # through while `!= []` on a literal is a comparison the compiler can
    # already decide.
    assert length(@credentialed_pairs) == 2,
           "the credentialed-pair table holds #{length(@credentialed_pairs)} entries, not 2. " <>
             "If a probe genuinely stopped being credentialed, say so here; if one was " <>
             "removed because this test failed, that failure was the point."

    source = breakers_source()

    for pair <- @credentialed_pairs do
      assert probe_body(source, pair.probe),
             "could not find #{pair.probe}/0 in circuit_breakers.ex. It was renamed or " <>
               "removed, so every assertion about it below is vacuous."

      assert File.exists?(Path.join(@repo_root, pair.production)),
             "#{pair.production} does not exist, so there is nothing to compare #{pair.probe} " <>
               "against"
    end
  end

  describe "a probe reads the same credential as its production caller" do
    test "the config key and credential header name match, per pair" do
      source = breakers_source()

      for pair <- @credentialed_pairs do
        body = probe_body(source, pair.probe)
        production = File.read!(Path.join(@repo_root, pair.production))

        assert body =~ pair.config_key,
               "#{pair.probe}/0 no longer reads #{pair.config_key}. If production rotated to " <>
                 "a different config key and the probe kept the old one, #{pair.fuse} closes " <>
                 "on a credential production does not use."

        assert production =~ pair.config_key,
               "#{pair.production} no longer reads #{pair.config_key} while #{pair.probe}/0 " <>
                 "still does, so the probe is now authenticating with a key production has " <>
                 "stopped using — the fuse will report healthy through a total outage."

        assert body =~ pair.header,
               "#{pair.probe}/0 no longer sends the #{pair.header} header"

        assert production =~ pair.header,
               "#{pair.production} no longer sends #{pair.header} while #{pair.probe}/0 " <>
                 "still does. The probe is exercising an auth scheme production has left " <>
                 "behind, which is exactly the state in which a fuse lies."
      end
    end

    test "the two probes that share production's own code are still sharing it" do
      # `probe_google_books` and `probe_resend` are not in the table above
      # because they do something better than matching: they reuse production's
      # own credential source, so there is no second copy to drift.
      #
      # `google_books_probe_url/0` builds its URL with
      # `ISBNResolver.google_books_url/1` — production's builder, key included.
      # `resend_api_key/0` reads `Application.get_env(:core, Stacks.Email.Mailer)`
      # — the mailer's own configuration, which is what production sends with.
      #
      # So the invariant for these two is "still delegating", and restating
      # their credentials here would create the duplication the delegation
      # avoids.
      source = breakers_source()

      assert source =~ "ISBNResolver.google_books_url(",
             "the Google Books probe no longer builds its URL with production's own builder. " <>
               "If it has grown its own copy of the URL and key handling, add it to " <>
               "@credentialed_pairs — a second copy is exactly what drifts."

      assert source =~ "Application.get_env(Stacks.Email.Mailer, [])" or
               source =~ "get_env(Stacks.Email.Mailer",
             "the Resend probe no longer reads the mailer's own configuration, so it can now " <>
               "probe with a different key than production sends with."
    end
  end

  describe "a probe with no credential refuses to probe" do
    setup do
      originals = %{
        brave: Application.get_env(:core, :brave_search_api_key),
        together: Application.get_env(:core, :vision_together_api_key)
      }

      on_exit(fn ->
        restore = fn key, value ->
          case value do
            nil -> Application.delete_env(:core, key)
            v -> Application.put_env(:core, key, v)
          end
        end

        restore.(:brave_search_api_key, originals.brave)
        restore.(:vision_together_api_key, originals.together)
      end)

      :ok
    end

    test "an unconfigured key yields :api_key_not_configured rather than a keyless probe" do
      # The behavioural half, and the one that matters most. The alternative
      # failure is subtle: probing keyless against an endpoint that answers 200
      # to anonymous callers would close the fuse while production, which does
      # send a key, is being rejected for a bad one.
      Application.delete_env(:core, :brave_search_api_key)
      Application.delete_env(:core, :vision_together_api_key)

      assert CircuitBreakers.probe_brave() == {:error, :api_key_not_configured},
             "the Brave probe ran without an API key. Brave 401s keyless requests, so " <>
               "whatever this probe concluded, it did not learn anything about production's " <>
               "ability to search."

      assert CircuitBreakers.probe_together_ai() == {:error, :api_key_not_configured},
             "the Together AI probe ran without an API key"
    end

    test "an empty-string key counts as absent" do
      # The shape a missing secret actually takes in a deployed environment: a
      # staged-but-unset Fly secret arrives as "", not as nil. A guard that only
      # checks for nil probes with an empty Bearer token and reports whatever
      # the upstream says about it.
      Application.put_env(:core, :brave_search_api_key, "")
      Application.put_env(:core, :vision_together_api_key, "")

      assert CircuitBreakers.probe_brave() == {:error, :api_key_not_configured},
             "an empty-string Brave key was treated as present. An unset Fly secret arrives " <>
               "as an empty string, so this is the common case, not the exotic one."

      assert CircuitBreakers.probe_together_ai() == {:error, :api_key_not_configured},
             "an empty-string Together AI key was treated as present"
    end
  end
end
