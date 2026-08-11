defmodule Stacks.Workers.EmailDeliveryJobTest do
  @moduledoc """
  Tests for Stacks.Workers.EmailDeliveryJob.

  Defaults to Swoosh.Adapters.Test (configured in test.exs) which stores
  delivered emails in the test process for assertion. Setting
  TEST_EMAIL_RECIPIENT (issue #258) opts into the real Resend adapter and
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
    test "registration_confirmation enqueues a job whose args.params.token is present" do
      user = user_with_confirmation_token()

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
end
