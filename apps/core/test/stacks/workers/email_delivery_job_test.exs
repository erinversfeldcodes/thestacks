defmodule Stacks.Workers.EmailDeliveryJobTest do
  @moduledoc """
  Tests for Stacks.Workers.EmailDeliveryJob.

  Uses Swoosh.Adapters.Test (configured in test.exs) which stores delivered
  emails in the test process for assertion.
  """

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Swoosh.TestAssertions
  import Stacks.Factory

  alias Stacks.Email
  alias Stacks.Workers.EmailDeliveryJob

  describe "perform/1 — notification preference gating" do
    test "delivers marketplace_sale when notify_marketplace is true" do
      user = insert(:user, notify_marketplace: true)

      assert :ok =
               perform_job(EmailDeliveryJob, %{
                 "template" => "marketplace_sale",
                 "user_id" => user.id,
                 "params" => %{"role" => "seller", "book_title" => "Dune"}
               })

      assert_email_sent(subject: "Book transaction update — The Stacks")
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
      user = insert(:user, notify_wishlist_availability: true)

      assert :ok =
               perform_job(EmailDeliveryJob, %{
                 "template" => "wishlist_availability",
                 "user_id" => user.id,
                 "params" => %{"book_title" => "The Name of the Rose"}
               })

      assert_email_sent(subject: "A book on your WishList is available — The Stacks")
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
      user = insert(:user, notify_marketplace: false, notify_wishlist_availability: false)
      token = Phoenix.Token.sign(CoreWeb.Endpoint, "email_confirm", user.id)

      assert :ok =
               perform_job(EmailDeliveryJob, %{
                 "template" => "registration_confirmation",
                 "user_id" => user.id,
                 "params" => %{"token" => token}
               })

      assert_email_sent(subject: "Confirm your email — The Stacks")
    end

    test "delivers password_reset regardless of prefs" do
      user = insert(:user, notify_marketplace: false)
      token = Phoenix.Token.sign(CoreWeb.Endpoint, "password_reset", user.id)

      assert :ok =
               perform_job(EmailDeliveryJob, %{
                 "template" => "password_reset",
                 "user_id" => user.id,
                 "params" => %{"token" => token}
               })

      assert_email_sent(subject: "Reset your password — The Stacks")
    end

    test "delivers gdpr_export_ready regardless of prefs" do
      user = insert(:user, notify_marketplace: false)

      assert :ok =
               perform_job(EmailDeliveryJob, %{
                 "template" => "gdpr_export_ready",
                 "user_id" => user.id,
                 "params" => %{"download_url" => "https://example.com/export.zip"}
               })

      assert_email_sent(subject: "Your data export is ready — The Stacks")
    end
  end

  # Punch #7 (Issue #124): enqueue shape + rate limiting. Emails are enqueued as
  # EmailDeliveryJob rows by Stacks.Email; the enqueuer enforces a per-user
  # (10/hr) and a global (100/hr) cap before writing any job. The confirmation
  # job must always carry params.token so the worker can build the link.
  describe "enqueue shape (Stacks.Email -> EmailDeliveryJob)" do
    test "registration_confirmation enqueues a job whose args.params.token is present" do
      user = insert(:user)

      assert {:ok, _user} = Email.send_registration_confirmation(user)

      assert_enqueued(worker: EmailDeliveryJob, args: %{"user_id" => user.id})

      [job] = all_enqueued(worker: EmailDeliveryJob)
      assert job.args["template"] == "registration_confirmation"
      assert is_binary(job.args["params"]["token"])
      assert job.args["params"]["token"] != ""
    end
  end

  describe "rate limiting" do
    test "per-user limit: the 11th confirmation within the hour is rejected" do
      user = insert(:user)

      # 10 successful enqueues fill the per-user hourly bucket.
      for _ <- 1..10 do
        assert {:ok, _user} = Email.send_registration_confirmation(user)
      end

      # The 11th is rate limited — no further job is enqueued for this user.
      assert {:error, :rate_limited} = Email.send_registration_confirmation(user)

      assert length(all_enqueued(worker: EmailDeliveryJob)) == 10
    end

    test "global limit: a fresh user is rejected once 100 emails are in-flight" do
      # Saturate the global hourly bucket with jobs from other recipients.
      for _ <- 1..100 do
        EmailDeliveryJob.new(%{
          "template" => "registration_confirmation",
          "user_id" => Ecto.UUID.generate(),
          "params" => %{"token" => "seed"}
        })
        |> Oban.insert!()
      end

      # A brand-new user (0 personal emails) is still blocked by the global cap.
      fresh_user = insert(:user)
      assert {:error, :rate_limited} = Email.send_registration_confirmation(fresh_user)
    end
  end

  describe "perform/1 — unknown template" do
    test "discards the job immediately without retrying" do
      user = insert(:user)

      # {:discard, reason} prevents Oban from retrying the job.
      # This protects the queue from jobs that can never succeed.
      assert {:discard, "unknown email template: " <> _} =
               perform_job(EmailDeliveryJob, %{
                 "template" => "carrier_pigeon",
                 "user_id" => user.id,
                 "params" => %{}
               })

      assert_no_email_sent()
    end
  end
end
