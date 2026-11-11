defmodule StacksWeb.InviteControllerTest do
  @moduledoc """
      The public invitation lookup — the one endpoint a person who has not got
      an account can reach with a credential in hand.

      The property this file exists for is the one that is invisible in a
      response body: **the code must not reach the request log.** Phoenix logs
      `conn.request_path` and the parameter map at `:info` on every request, so
      a code carried in the path is a live credential written into the
      application log on every attempt, and nothing about the path form can be
      filtered. The shape test and the log test below are the two halves of
      that: the code travels in the body, and the body is filtered.
  """
  use CoreWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts.Invites

  defp mint(attrs \\ %{}) do
    owner = insert(:user, role: "owner")
    {:ok, %{invite: invite, code: code}} = Invites.issue(owner, attrs)
    %{owner: owner, invite: invite, code: code}
  end

  defp check(conn, code) do
    post(conn, "/api/auth/invite/check", %{"code" => code})
  end

  describe "a redeemable code" do
    test "answers valid, and says whether it is bound to an address without naming it", %{
      conn: conn
    } do
      %{code: code} = mint(%{"invited_email" => "mara@example.test"})

      body = conn |> check(code) |> json_response(200)

      assert body["valid"] == true
      assert body["email_bound"] == true
      refute body["expires_at"] == nil

      # The whole payload, not just the fields asserted above: a lookup a
      # stranger can reach must not grow a field that names a person.
      assert Map.keys(body) |> Enum.sort() == ["email_bound", "expires_at", "valid"]
    end

    test "an unbound code says so", %{conn: conn} do
      %{code: code} = mint()

      assert conn |> check(code) |> json_response(200) |> Map.get("email_bound") == false
    end
  end

  describe "the four refusals keep their distinct statuses" do
    test "an unknown code is 404", %{conn: conn} do
      body = conn |> check("no-such-code") |> json_response(404)
      assert body["error"] == "invite_not_found"
    end

    test "an expired code is 410", %{conn: conn} do
      %{invite: invite, code: code} = mint()

      invite
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :day))
      |> Repo.update!()

      assert conn |> check(code) |> json_response(410) |> Map.get("error") == "invite_expired"
    end

    test "a revoked code is 403", %{conn: conn} do
      %{invite: invite, code: code} = mint()

      invite
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
      |> Repo.update!()

      assert conn |> check(code) |> json_response(403) |> Map.get("error") == "invite_revoked"
    end

    test "a spent code is 409", %{conn: conn} do
      %{invite: invite, code: code} = mint()

      invite |> Ecto.Changeset.change(use_count: invite.max_uses) |> Repo.update!()

      assert conn |> check(code) |> json_response(409) |> Map.get("error") == "invite_exhausted"
    end
  end

  describe "a missing code" do
    test "answers not-found rather than crashing or 400ing", %{conn: conn} do
      body = conn |> post("/api/auth/invite/check", %{}) |> json_response(404)
      assert body["error"] == "invite_not_found"
    end

    test "a blank code answers the same, revealing nothing a prober can use", %{conn: conn} do
      assert conn |> check("") |> json_response(404) |> Map.get("error") == "invite_not_found"
    end

    test "a code that is not a string answers the same, and never 500s", %{conn: conn} do
      # This endpoint is unauthenticated and pre-account, and its whole design is
      # that a prober learns nothing from the response. A 500 with a stacktrace
      # is the most informative answer it could possibly give, and coercing the
      # value instead — a charlist becoming a string, a number becoming its
      # digits — is guessing at an intent it has no business guessing.
      for value <- [%{"a" => 1}, [104, 105], 12, true, nil] do
        body = conn |> post("/api/auth/invite/check", %{"code" => value}) |> json_response(404)
        assert body["error"] == "invite_not_found"
      end
    end
  end

  describe "the code does not reach the request log" do
    setup do
      # The test environment runs the Logger at `:warning`, which drops request
      # logging at the source — so a capture here would be empty whatever the
      # endpoint did, and the test would pass by observing nothing.
      #
      # `:debug`, not `:info`, because the two logged lines sit at DIFFERENT
      # levels and the code could leak into either: the access line ("POST
      # /path") is `:info` and carries `request_path`, while the "Parameters:"
      # line is `:debug` and carries the body. Capturing only at `:info` would
      # silently exempt the half that `:filter_parameters` defends.
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)
    end

    test "neither the logged path nor the logged parameters carry it", %{conn: conn} do
      %{code: code} = mint()

      logged =
        capture_log([level: :debug], fn ->
          assert conn |> check(code) |> json_response(200) |> Map.get("valid") == true
        end)

      # Both lines WERE logged — otherwise this test passes by observing nothing,
      # which would prove the opposite of what it claims.
      assert logged =~ "/api/auth/invite/check"
      assert logged =~ "Parameters:"

      refute logged =~ code
      assert logged =~ "[FILTERED]"
    end
  end
end
