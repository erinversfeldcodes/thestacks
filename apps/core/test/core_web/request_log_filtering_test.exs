defmodule CoreWeb.RequestLogFilteringTest do
  @moduledoc """
      Phoenix prints the parameter map on every request, so anything that is
      itself a credential has to be named in `:filter_parameters` or it lands in
      the application log — and from there in whatever aggregates logs.

      The regression this exists for: setting `:filter_parameters` REPLACES
      Phoenix's own `["password"]` default rather than adding to it, so removing
      a name from the list does not fall back to anything safe. Deleting
      `"password"` would return every password in the system to the log, and
      before this the only test of this configuration happened to be about
      invitation codes.

      Asserted BEHAVIOURALLY, one request carrying all four, rather than by
      reading the configured list back: Phoenix replaces that value at boot with
      compiled binary-match patterns, so the list is not readable at runtime and
      a test that tried would be asserting against an opaque tuple.

      The request goes to a path no route matches, which the API fallback answers
      with a 404 — a real trip through the endpoint, the parser and the logger,
      and the one way to put every credential name in a single parameter map
      without inventing an endpoint that accepts them.
  """
  use CoreWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  # Each names a credential this system actually sends as a parameter: a password
  # on login and registration, an invitation or MFA code, a refresh or
  # confirmation token, a partner secret. Matching is by substring, so `code`
  # also covers `invite_code` and `mfa_code`.
  @credential_params %{
    "password" => "pw-must-not-be-logged",
    "code" => "code-must-not-be-logged",
    "token" => "token-must-not-be-logged",
    "secret" => "secret-must-not-be-logged",
    "invite_code" => "invite-code-must-not-be-logged"
  }

  setup do
    # The test environment runs the Logger at `:warning`, and the parameter line
    # is `:debug`, so a capture without this observes nothing at all and the test
    # would pass whatever the filter did.
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
  end

  describe "every credential-bearing parameter" do
    test "is replaced in the request log", %{conn: conn} do
      logged =
        capture_log([level: :debug], fn ->
          post(conn, "/api/log-filter-probe", @credential_params)
        end)

      # Positive control first. Without these the refutes below pass by observing
      # an empty string, which proves the opposite of what they claim.
      assert logged =~ "/api/log-filter-probe"
      assert logged =~ "Parameters:"
      assert logged =~ "[FILTERED]"

      for {key, value} <- @credential_params do
        refute logged =~ value,
               "the #{inspect(key)} parameter reached the request log in full — this key is " <>
                 "either missing from `:filter_parameters` or that setting is gone, and " <>
                 "setting it REPLACES Phoenix's default rather than adding to it, so there " <>
                 "is no safe fallback to revert to"
      end
    end

    test "a parameter that is NOT a credential is still logged, so the filter is not blanket", %{
      conn: conn
    } do
      # Otherwise the test above would pass against a filter that redacted
      # everything, which would be useless rather than safe: the parameter line
      # exists to make a request diagnosable.
      logged =
        capture_log([level: :debug], fn ->
          post(conn, "/api/log-filter-probe", %{"handle" => "mara-the-reader"})
        end)

      assert logged =~ "mara-the-reader"
    end
  end
end
