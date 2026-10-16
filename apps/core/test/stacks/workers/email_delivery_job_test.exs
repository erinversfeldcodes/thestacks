defmodule Stacks.Workers.EmailDeliveryJobTest do
  @moduledoc """
      Tests for Stacks.Workers.EmailDeliveryJob.

      Defaults to Swoosh.Adapters.Test (configured in test.exs) which stores
      delivered emails in the test process for assertion. Setting
      TEST_EMAIL_RECIPIENT (issue) opts into the real Resend adapter and
      routes deliveries to that address; delivery assertions are adapter-aware
      (`assert_delivered/1`) so the same tests pass under either adapter.
  """

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Swoosh.TestAssertions
  import Stacks.Factory

  alias Stacks.Email
  alias Stacks.Workers.EmailDeliveryJob

  defp recipient_opts do
    case System.get_env("TEST_EMAIL_RECIPIENT") do
      nil -> []
      "" -> []
      addr -> [email: addr]
    end
  end

  defp assert_delivered(subject) do
    if Application.get_env(:core, Stacks.Email.Mailer)[:adapter] == Swoosh.Adapters.Test do
      assert_email_sent(subject: subject)
    end
  end

  defp user_with_confirmation_token do
    user = insert(:user, email_confirmed: false)
    token = Phoenix.Token.sign(CoreWeb.Endpoint, "email_confirm", user.id)

    {:ok, user} =
      user |> Ecto.Changeset.change(%{email_confirmation_token: token}) |> Core.Repo.update()

    user
  end

  describe "perform/1 — notification preference gating" do
    test "delivers marketplace_sale when notify_marketplace is true" do
      user = insert(:user, [notify_marketplace: true] ++ recipient_opts())

      assert :ok =
               perform_job(EmailDeliveryJob, %{
                 "template" => "marketplace_sale",
                 "user_id" => user.id,
                 "params" => %{"role" => "seller", "book_title" => "Dune"}
               })

      assert_delivered("Book transaction update — The Stacks")
    end

    test "skips marketplace_sale when notify_marketplace is false" do
      user = insert(:user, notify_marketplace: false)

      assert :ok =
               perform_job(EmailDeliveryJob, %{
                 "template" => "marketplace_sale",
                 "user_id" => user.id,
                 "params" => %{"role" => "buyer", "book_title" => "Dune"}
               })

      assert_no_email_sent()
    end

    test "delivers wishlist_availability when notify_wishlist_availability is true" do
      user = insert(:user, [notify_wishlist_availability: true] ++ recipient_opts())

      assert :ok =
               perform_job(EmailDeliveryJob, %{
                 "template" => "wishlist_availability",
                 "user_id" => user.id,
                 "params" => %{"book_title" => "The Name of the Rose"}
               })

      assert_delivered("A book on your WishList is available — The Stacks")
    end

    test "skips wishlist_availability when notify_wishlist_availability is false" do
      user = insert(:user, notify_wishlist_availability: false)

      assert :ok =
               perform_job(EmailDeliveryJob, %{
                 "template" => "wishlist_availability",
                 "user_id" => user.id,
                 "params" => %{"book_title" => "The Name of the Rose"}
               })

      assert_no_email_sent()
    end
  end

  describe "perform/1 — bypass preference templates" do
    test "delivers registration_confirmation regardless of prefs" do
      user =
        insert(
          :user,
          [notify_marketplace: false, notify_wishlist_availability: false] ++ recipient_opts()
        )

      token = Phoenix.Token.sign(CoreWeb.Endpoint, "email_confirm", user.id)

      assert :ok =
               perform_job(EmailDeliveryJob, %{
                 "template" => "registration_confirmation",
                 "user_id" => user.id,
                 "params" => %{"token" => token}
               })

      assert_delivered("Confirm your email — The Stacks")
    end

    test "delivers password_reset regardless of prefs" do
      user = insert(:user, [notify_marketplace: false] ++ recipient_opts())
      token = Phoenix.Token.sign(CoreWeb.Endpoint, "password_reset", user.id)

      assert :ok =
               perform_job(EmailDeliveryJob, %{
                 "template" => "password_reset",
                 "user_id" => user.id,
                 "params" => %{"token" => token}
               })

      assert_delivered("Reset your password — The Stacks")
    end

    test "delivers gdpr_export_ready regardless of prefs" do
      user = insert(:user, [notify_marketplace: false] ++ recipient_opts())

      assert :ok =
               perform_job(EmailDeliveryJob, %{
                 "template" => "gdpr_export_ready",
                 "user_id" => user.id,
                 "params" => %{"download_url" => "https://example.com/export.zip"}
               })

      assert_delivered("Your data export is ready — The Stacks")
    end
  end

  describe "enqueue shape (Stacks.Email -> EmailDeliveryJob)" do
    test "no enqueued job carries a usable credential in its args" do
      # ⚠️ This test used to assert the OPPOSITE — that `args.params.token` was
      # present and non-empty. It was pinning a defect.
      #
      # `oban_jobs.args` is an ordinary queryable table with no erasure path.
      # A confirmation or reset token sitting there is a live credential: the
      # reset token verifies for 24 hours and the confirmation tokens are
      # compared straight against the user row with no expiry at all, so they
      # work until consumed. The job never needed the token — it loads the user
      # row anyway and can read the live one at delivery.
      #
      # Raising the Oban pruner from 60 seconds to 7 days is what made this
      # urgent rather than merely wrong: the same credential, readable for
      # 10,080× longer.
      user = user_with_confirmation_token()

      assert {:ok, _user} = Email.send_registration_confirmation(user)
      assert_enqueued(worker: EmailDeliveryJob, args: %{"user_id" => user.id})

      [job] = all_enqueued(worker: EmailDeliveryJob)
      assert job.args["template"] == "registration_confirmation"

      refute Map.has_key?(job.args["params"], "token"),
             "a raw token reached oban_jobs.args: #{inspect(job.args["params"])}. The worker " <>
               "resolves the live token from the user row — nothing needs to carry it through " <>
               "the queue."

      assert job.args["user_id"] == user.id,
             "the args must still identify the user, or the worker cannot resolve the token"
    end

    test "the email-change pair carries a DIGEST, which cannot be used as a token" do
      # The two templates that genuinely need something from the enqueue: the
      # worker compares against the user row to detect a change that has been
      # settled or superseded since. A SHA-256 digest answers that question and
      # is useless to anyone reading the table.
      user = user_mid_change()

      assert {:ok, _} = Email.send_email_change_pair(user)

      jobs = all_enqueued(worker: EmailDeliveryJob)
      confirmation = Enum.find(jobs, &(&1.args["template"] == "email_change_confirmation"))

      refute is_nil(confirmation), "the confirmation letter was not enqueued"

      digest = confirmation.args["params"]["token_digest"]

      assert is_binary(digest) and byte_size(digest) == 64,
             "expected a hex SHA-256 digest, got #{inspect(digest)}"

      refute digest == user.pending_email_token,
             "the digest is the token itself — hashing did not happen"

      assert digest == EmailDeliveryJob.digest_of(user.pending_email_token),
             "the digest must be of the token it supersedes, or staleness cannot be judged"
    end
  end

  describe "rate limiting" do
    test "per-user limit: the 11th confirmation within the hour is rejected" do
      user = user_with_confirmation_token()

      for _ <- 1..10 do
        assert {:ok, _user} = Email.send_registration_confirmation(user)
      end

      assert {:error, :rate_limited} = Email.send_registration_confirmation(user)

      assert length(all_enqueued(worker: EmailDeliveryJob)) == 10
    end

    test "global limit: a fresh user is rejected once 100 emails are in-flight" do
      for _ <- 1..100 do
        EmailDeliveryJob.new(%{
          "template" => "registration_confirmation",
          "user_id" => Ecto.UUID.generate(),
          "params" => %{"token" => "seed"}
        })
        |> Oban.insert!()
      end

      fresh_user = insert(:user)
      assert {:error, :rate_limited} = Email.send_registration_confirmation(fresh_user)
    end
  end

  describe "perform/1 — the two letters an email change is made of" do
    defp user_mid_change(attrs \\ []) do
      user = insert(:user, [email: "old@thestacks.test"] ++ attrs)

      {:ok, pending} =
        user
        |> Stacks.Accounts.pending_email_changeset(%{
          pending_email: "new@thestacks.test",
          pending_email_token: "confirm-token",
          pending_email_sent_at: DateTime.utc_now(),
          pending_email_revert_token: "revert-token"
        })
        |> Core.Repo.update()

      pending
    end

    test "the confirmation goes to the PENDING address, not the account's" do
      user = user_mid_change()

      assert :ok =
               perform_job(EmailDeliveryJob, %{
                 "template" => "email_change_confirmation",
                 "user_id" => user.id,
                 "params" => %{"token" => "confirm-token"}
               })

      if Application.get_env(:core, Stacks.Email.Mailer)[:adapter] == Swoosh.Adapters.Test do
        assert_email_sent(fn email ->
          assert email.to == [{"", "new@thestacks.test"}]
          assert email.subject == "Confirm your new email address — The Stacks"
          assert email.html_body =~ "/api/auth/confirm-email-change/confirm-token"
        end)
      end
    end

    test "the notice goes to the account's address and names what it is being changed to" do
      user = user_mid_change()

      assert :ok =
               perform_job(EmailDeliveryJob, %{
                 "template" => "email_change_notice",
                 "user_id" => user.id,
                 "params" => %{"token" => "revert-token"}
               })

      if Application.get_env(:core, Stacks.Email.Mailer)[:adapter] == Swoosh.Adapters.Test do
        assert_email_sent(fn email ->
          assert [{_name, "old@thestacks.test"}] = email.to
          assert email.html_body =~ "new@thestacks.test"
          assert email.html_body =~ "/api/auth/revert-email-change/revert-token"
        end)
      end
    end

    test "a change settled before delivery discards its letters rather than mailing dead links" do
      user = user_mid_change()

      {:ok, _settled} =
        user
        |> Stacks.Accounts.pending_email_changeset(%{
          pending_email: nil,
          pending_email_token: nil,
          pending_email_sent_at: nil,
          pending_email_revert_token: nil
        })
        |> Core.Repo.update()

      assert {:discard, _} =
               perform_job(EmailDeliveryJob, %{
                 "template" => "email_change_confirmation",
                 "user_id" => user.id,
                 "params" => %{"token" => "confirm-token"}
               })

      assert {:discard, _} =
               perform_job(EmailDeliveryJob, %{
                 "template" => "email_change_notice",
                 "user_id" => user.id,
                 "params" => %{"token" => "revert-token"}
               })

      assert_no_email_sent()
    end

    test "a superseded change discards the letters of the change it replaced" do
      user = user_mid_change()

      {:ok, _resupplied} =
        user
        |> Stacks.Accounts.pending_email_changeset(%{
          pending_email: "newer@thestacks.test",
          pending_email_token: "second-confirm-token",
          pending_email_sent_at: DateTime.utc_now(),
          pending_email_revert_token: "second-revert-token"
        })
        |> Core.Repo.update()

      assert {:discard, _} =
               perform_job(EmailDeliveryJob, %{
                 "template" => "email_change_confirmation",
                 "user_id" => user.id,
                 "params" => %{"token" => "confirm-token"}
               })

      assert_no_email_sent()
    end
  end

  describe "perform/1 — unknown template" do
    test "discards the job immediately without retrying" do
      user = insert(:user)

      assert {:discard, "unknown email template: " <> _} =
               perform_job(EmailDeliveryJob, %{
                 "template" => "carrier_pigeon",
                 "user_id" => user.id,
                 "params" => %{}
               })

      assert_no_email_sent()
    end
  end

  describe "delivery counter" do
    # The public cost page's email line is derived from this counter. It used to
    # be derived by counting rows in `oban_jobs`, which the pruner deletes about
    # a minute after a job completes, so the month-to-date figure only ever saw
    # the last minute of sends.
    test "a delivered email emits the counted event, tagged with its template" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:stacks, :email, :delivered]])
      user = insert(:user, recipient_opts())

      assert :ok =
               perform_job(EmailDeliveryJob, %{
                 "user_id" => user.id,
                 "template" => "password_reset",
                 "params" => %{"token" => "tok"}
               })

      assert_receive {[:stacks, :email, :delivered], ^ref, %{count: 1},
                      %{template: :password_reset}}
    end
  end
end
