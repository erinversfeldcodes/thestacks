defmodule Stacks.DiscoveryRemovalReviewTest do
  @moduledoc """
  The removal-request review queue (US-2.5.3, campaign G6).

  A request whose contact address does not match the listing's domain parks with
  `exclusion_requested_at` set and `status` untouched — that pair *is* the pending state.

  ⚠️ **It was invisible.** `serialize_source/1` did not carry `exclusion_requested_at`, so
  a business whose request could not be auto-verified waited on a human who had no way to
  know they were waiting. A queue nobody can see is indistinguishable from a request that
  was silently refused, which is the outcome US-2.5.3 exists to prevent.
  """

  use Core.DataCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Discovery
  alias Stacks.Enrichment.ThirdSpace
  alias Stacks.Geocoding.Mock, as: MockGeocoder

  setup do
    original = Application.get_env(:core, :geocoder)
    Application.put_env(:core, :geocoder, MockGeocoder)

    on_exit(fn ->
      MockGeocoder.clear()

      if original,
        do: Application.put_env(:core, :geocoder, original),
        else: Application.delete_env(:core, :geocoder)
    end)

    :ok
  end

  defp approved_source(url \\ "https://readingroom.test") do
    source =
      insert(:discovered_source,
        name: "The Reading Room",
        type: "community",
        url: url,
        status: "pending_review",
        discovered_at: DateTime.utc_now()
      )

    MockGeocoder.put_point("The Reading Room", -33.9249, 18.4241)
    {:ok, approved} = Discovery.approve_source(source.id)
    approved
  end

  # An unverified request: the address is not on the listing's domain.
  defp parked_request(url \\ "https://readingroom.test") do
    source = approved_source(url)
    {:ok, :pending_review, parked} = Discovery.opt_out(url, %{email: "someone@gmail.test"})
    {source, parked}
  end

  describe "pending_removal_requests/0" do
    test "surfaces a request that could not be auto-verified" do
      {_source, _parked} = parked_request()

      assert [request] = Discovery.pending_removal_requests()
      assert request.url == "https://readingroom.test"
      assert request.exclusion_requested_at

      assert request.exclusion_email == "someone@gmail.test",
             "the reviewer needs the address — without it the queue is a list of names"
    end

    test "excludes a request that was auto-verified, because nobody needs to look" do
      approved_source()

      assert {:ok, :excluded, _} =
               Discovery.opt_out("https://readingroom.test", %{email: "owner@readingroom.test"})

      assert Discovery.pending_removal_requests() == []
    end

    test "excludes a source nobody has asked about" do
      approved_source()
      assert Discovery.pending_removal_requests() == []
    end

    test "oldest first — people waiting are served in the order they asked" do
      approved_source("https://first.test")
      approved_source("https://second.test")

      {:ok, :pending_review, _} =
        Discovery.opt_out("https://first.test", %{email: "a@gmail.test"})

      {:ok, :pending_review, _} =
        Discovery.opt_out("https://second.test", %{email: "b@gmail.test"})

      urls = Discovery.pending_removal_requests() |> Enum.map(& &1.url)
      assert urls == ["https://first.test", "https://second.test"]
    end
  end

  describe "honour_removal_request/1 — the listing goes" do
    test "excludes the source and delists the third space" do
      {_source, parked} = parked_request()

      assert {:ok, honoured} = Discovery.honour_removal_request(parked.id)
      assert honoured.status == "excluded"
      assert honoured.excluded_at

      assert [%{opted_out: true}] = Repo.all(ThirdSpace),
             "the listing a reader sees is still up after the removal was honoured"
    end

    test "the request leaves the queue" do
      {_source, parked} = parked_request()
      assert {:ok, _} = Discovery.honour_removal_request(parked.id)
      assert Discovery.pending_removal_requests() == []
    end

    test "ends in the same state as an auto-verified removal" do
      # There must be one notion of "removed". If a hand-reviewed removal left a different
      # state, some later query would treat the two differently.
      {_source, parked} = parked_request("https://byhand.test")
      assert {:ok, by_hand} = Discovery.honour_removal_request(parked.id)

      approved_source("https://auto.test")

      assert {:ok, :excluded, automatic} =
               Discovery.opt_out("https://auto.test", %{email: "owner@auto.test"})

      assert by_hand.status == automatic.status
      assert Enum.all?(Repo.all(ThirdSpace), & &1.opted_out)
    end

    test "refuses a request that was already decided" do
      # 409, not 404: a double-click or a second reviewer must not silently re-run a
      # decision, and must not read as "never existed".
      {_source, parked} = parked_request()
      assert {:ok, _} = Discovery.honour_removal_request(parked.id)
      assert {:error, :not_pending} = Discovery.honour_removal_request(parked.id)
    end

    test "refuses a source with no request against it" do
      source = approved_source()
      assert {:error, :not_pending} = Discovery.honour_removal_request(source.id)
    end

    test "refuses an unknown id" do
      assert {:error, :not_found} = Discovery.honour_removal_request(Ecto.UUID.generate())
    end
  end

  describe "decline_removal_request/1 — the listing stays" do
    test "leaves the listing live and clears the request" do
      {_source, parked} = parked_request()

      assert {:ok, declined} = Discovery.decline_removal_request(parked.id)
      refute declined.status == "excluded"
      assert is_nil(declined.exclusion_requested_at)

      assert [%{opted_out: false}] = Repo.all(ThirdSpace),
             "declining a request delisted the business anyway"
    end

    test "the request leaves the queue" do
      {_source, parked} = parked_request()
      assert {:ok, _} = Discovery.decline_removal_request(parked.id)
      assert Discovery.pending_removal_requests() == []
    end

    test "keeps the contact address on record" do
      # A declined request is worth remembering: if the same business asks again, a repeat
      # should not look like a first contact.
      {_source, parked} = parked_request()
      assert {:ok, declined} = Discovery.decline_removal_request(parked.id)

      assert declined.exclusion_email == "someone@gmail.test",
             "the address was discarded, so a second request would look like a first"
    end

    test "cannot un-exclude a listing that was already removed" do
      # The dangerous direction: decline must not be a way to resurrect a removed business.
      {_source, parked} = parked_request()
      assert {:ok, _} = Discovery.honour_removal_request(parked.id)

      assert {:error, :not_pending} = Discovery.decline_removal_request(parked.id)

      assert [%{opted_out: true}] = Repo.all(ThirdSpace)
    end
  end

  describe "the two decisions are not confusable with approving a listing" do
    test "approve_source publishes; honour_removal_request unpublishes" do
      # ⚠️ Both were nearly called "approve". `approve_source/1` means *publish this
      # listing*; honouring a removal means *take it down*. Same word, opposite effect, on
      # the same row — so the names differ and this test says why.
      {_source, parked} = parked_request()

      assert {:ok, honoured} = Discovery.honour_removal_request(parked.id)
      assert honoured.status == "excluded"

      # And approving is still refused afterwards: an excluded source is not pending_review.
      assert {:error, :invalid_transition} = Discovery.approve_source(parked.id)
    end

    test "a delisted business is not re-listed by re-approval" do
      {_source, parked} = parked_request()
      assert {:ok, _} = Discovery.honour_removal_request(parked.id)

      # Even calling the producer directly must not resurrect it.
      Discovery.create_third_space(Discovery.get_source(parked.id))

      assert length(Repo.all(from(s in ThirdSpace))) == 1
      assert [%{opted_out: true}] = Repo.all(ThirdSpace)
    end
  end
end
