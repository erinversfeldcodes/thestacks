defmodule Stacks.Workers.IdentifyBookJobTerminalTest do
  @moduledoc """
  The terminal guarantee, swept over EVERY failure branch rather than one
  test per bug — the defect is a class (an exit that forgets to mark the
  row, leaving the reader a spinner), and testing the two known-broken
  branches proves nothing about the third. Asserts across the branch
  table: the row always reaches a terminal status on the final attempt,
  and deterministic errors cancel instead of burning GPU retries.
  """

  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.AI.Client, as: AIClient
  alias Stacks.AI.MockClient
  alias Stacks.Books.UploadedImage
  alias Stacks.Storage.Mock, as: StorageMock
  alias Stacks.Workers.IdentifyBookJob

  @image_b64 Base.encode64("fake image bytes for testing")

  setup do
    original = Application.get_env(:core, :vision_client)
    Application.put_env(:core, :vision_client, MockClient)
    on_exit(fn -> Application.put_env(:core, :vision_client, original) end)

    MockClient.clear()
    :ok
  end

  @vision_failures [
    {:circuit_open, {:error, :circuit_open}, :retryable},
    {:budget_exceeded, {:error, :budget_exceeded}, :retryable},
    {:undecodable_image, {:error, {:undecodable_image, "undecodable_image"}}, :deterministic},
    {:image_too_large, {:error, {:undecodable_image, "image_too_large"}}, :deterministic},
    {:image_unreachable, {:error, {:undecodable_image, "image_unreachable"}}, :deterministic},
    {:no_image_supplied, {:error, {:undecodable_image, "no_image_supplied"}}, :deterministic},
    {:malformed_request, {:error, {:undecodable_image, "malformed_request"}}, :deterministic},
    {:upstream_status, {:error, {:upstream_status, 503}}, :retryable},
    {:transport, {:error, {:transport, :closed}}, :retryable}
  ]

  @moderation_determinations [
    {:not_a_book, {:ok, %{"classification" => "CLASSIFICATION_RESULT_NOT_BOOK", "books" => []}},
     :deterministic},
    {:isbn_not_found, {:ok, %{"classification" => "CLASSIFICATION_RESULT_BOOK", "books" => []}},
     :deterministic},
    {:unrecognised_response, {:ok, %{"nonsense" => true}}, :retryable}
  ]

  defp crashes do
    [
      {:raise, fn _payload -> raise "vision client blew up" end, :retryable},
      {:throw, fn _payload -> throw(:vision_client_threw) end, :retryable},
      {:exit, fn _payload -> exit(:vision_client_exited) end, :retryable}
    ]
  end

  defp all_branches do
    @vision_failures ++ @moderation_determinations ++ crashes()
  end

  describe "terminal guarantee — final attempt" do
    test "no failure branch leaves the image row pending" do
      results =
        for {name, response, _kind} <- all_branches() do
          image = insert(:uploaded_image)
          MockClient.clear()
          MockClient.put_response("analyze", response)

          run_attempt(image.id, attempt: 3, max_attempts: 3)

          {name, Repo.get!(UploadedImage, image.id).status}
        end

      still_pending = for {name, "pending"} <- results, do: name

      assert still_pending == [],
             """
             These branches left the image row `pending` on the FINAL attempt.
             The job is dead; the reader is still watching a spinner and will
             keep watching until the SSE deadline expires.

               #{inspect(still_pending)}

             Full sweep: #{inspect(results)}
             """

      assert Enum.all?(results, fn {_name, status} -> status == "rejected" end),
             "expected every failure branch to end `rejected`, got #{inspect(results)}"
    end

    test "the storage presign failure path also ends terminal" do
      image = insert(:uploaded_image)

      StorageMock.put_presign_error(:signing_key_unavailable)
      on_exit(&StorageMock.clear/0)

      assert {:error, :signing_key_unavailable} =
               run_attempt(
                 image.id,
                 [attempt: 3, max_attempts: 3],
                 %{"storage_key" => "uploads/whatever.jpg"}
               )

      assert Repo.get!(UploadedImage, image.id).status == "rejected"
    end

    test "the storage presign failure is retried before it is terminal" do
      image = insert(:uploaded_image)
      StorageMock.put_presign_error(:signing_key_unavailable)
      on_exit(&StorageMock.clear/0)

      assert {:error, :signing_key_unavailable} =
               run_attempt(
                 image.id,
                 [attempt: 1, max_attempts: 3],
                 %{"storage_key" => "uploads/whatever.jpg"}
               )

      assert Repo.get!(UploadedImage, image.id).status == "pending"
    end

    test "args matching no dispatch clause cancel rather than raising past the guarantee" do
      image = insert(:uploaded_image)

      assert {:cancel, _} =
               perform_job(
                 IdentifyBookJob,
                 %{"user_id" => Ecto.UUID.generate(), "image_id" => image.id},
                 attempt: 1,
                 max_attempts: 3
               )

      assert Repo.get!(UploadedImage, image.id).status == "rejected"
    end

    test "zero-row sweep: no image row is left pending after the full branch sweep" do
      for {_name, response, _kind} <- all_branches() do
        image = insert(:uploaded_image)
        MockClient.clear()
        MockClient.put_response("analyze", response)
        run_attempt(image.id, attempt: 3, max_attempts: 3)
      end

      pending_count =
        Repo.aggregate(from(i in UploadedImage, where: i.status == "pending"), :count)

      assert pending_count == 0,
             "#{pending_count} uploaded_images row(s) left pending after sweeping " <>
               "#{length(all_branches())} failure branches"
    end
  end

  describe "terminal guarantee — non-final attempt" do
    test "a transient branch leaves the row pending so the retry can still succeed" do
      transient =
        for {name, response, :retryable} <- all_branches(), do: {name, response}

      results =
        for {name, response} <- transient do
          image = insert(:uploaded_image)
          MockClient.clear()
          MockClient.put_response("analyze", response)

          run_attempt(image.id, attempt: 1, max_attempts: 3)

          {name, Repo.get!(UploadedImage, image.id).status}
        end

      assert Enum.all?(results, fn {_name, status} -> status == "pending" end),
             """
             A transient failure on attempt 1 of 3 marked the row terminal.
             The wrapper is marking unconditionally instead of on the final
             attempt, which turns every recoverable blip into a rejected upload.

               #{inspect(results)}
             """
    end

    test "a deterministic branch is terminal on attempt 1, without waiting for retries" do
      deterministic =
        for {name, response, :deterministic} <- all_branches(), do: {name, response}

      results =
        for {name, response} <- deterministic do
          image = insert(:uploaded_image)
          MockClient.clear()
          MockClient.put_response("analyze", response)

          verdict = run_attempt(image.id, attempt: 1, max_attempts: 3)

          {name, verdict, Repo.get!(UploadedImage, image.id).status}
        end

      not_cancelled =
        for {name, verdict, _status} <- results, not match?({:cancel, _}, verdict), do: name

      assert not_cancelled == [],
             """
             These deterministic failures were returned to Oban as retryable
             errors. The service has already told us it cannot process this
             image; the retries re-prove it while the reader waits out the
             backoff schedule.

               #{inspect(not_cancelled)}
             """

      assert Enum.all?(results, fn {_n, _v, status} -> status == "rejected" end),
             "a determination on attempt 1 must mark the row now: #{inspect(results)}"
    end
  end

  describe "an attempt that simply runs too long" do
    setup do
      Application.put_env(:core, :identify_attempt_timeout_ms, 50)
      on_exit(fn -> Application.delete_env(:core, :identify_attempt_timeout_ms) end)
      :ok
    end

    defp slow_client_response do
      fn _payload ->
        Process.sleep(2_000)
        {:ok, %{"classification" => "CLASSIFICATION_RESULT_BOOK", "books" => []}}
      end
    end

    test "is terminal on the final attempt rather than left pending" do
      image = insert(:uploaded_image)
      MockClient.put_response("analyze", slow_client_response())

      assert {:error, :attempt_timeout} = run_attempt(image.id, attempt: 3, max_attempts: 3)
      assert Repo.get!(UploadedImage, image.id).status == "rejected"
    end

    test "is retried on a non-final attempt" do
      image = insert(:uploaded_image)
      MockClient.put_response("analyze", slow_client_response())

      assert {:error, :attempt_timeout} = run_attempt(image.id, attempt: 1, max_attempts: 3)
      assert Repo.get!(UploadedImage, image.id).status == "pending"
    end

    test "returns within the bound instead of waiting for the work" do
      image = insert(:uploaded_image)
      MockClient.put_response("analyze", slow_client_response())

      {elapsed_us, _} = :timer.tc(fn -> run_attempt(image.id, attempt: 3, max_attempts: 3) end)

      assert elapsed_us < 1_000_000,
             "the attempt bound did not fire — took #{div(elapsed_us, 1000)}ms"
    end
  end

  describe "retry split — attempt counts" do
    test "a deterministic failure calls the vision service exactly once" do
      image = insert(:uploaded_image)

      assert {calls, drained} =
               drain_counting_calls(image, {:error, {:undecodable_image, "undecodable_image"}})

      assert calls == 1,
             "a deterministic vision failure was retried on the GPU #{calls} times"

      assert drained.cancelled == 1, "expected Oban to record a cancel, got #{inspect(drained)}"
      assert drained.failure == 0
      assert Repo.get!(UploadedImage, image.id).status == "rejected"
    end

    test "a transient failure calls the vision service once per attempt, then stops" do
      image = insert(:uploaded_image)

      assert {calls, drained} = drain_counting_calls(image, {:error, {:transport, :closed}})

      assert calls == 3,
             "a transient failure should use its whole retry budget; it made #{calls} call(s)"

      assert drained.discard == 1,
             "expected the job to be discarded after exhausting attempts, got #{inspect(drained)}"

      assert Repo.get!(UploadedImage, image.id).status == "rejected",
             "exhausting the retry budget must still leave the reader with an answer"
    end

    test "the two splits differ in attempt count, not merely in outcome" do
      deterministic = insert(:uploaded_image)
      transient = insert(:uploaded_image)

      {det_calls, _} =
        drain_counting_calls(deterministic, {:error, {:undecodable_image, "image_too_large"}})

      {trans_calls, _} = drain_counting_calls(transient, {:error, :circuit_open})

      assert det_calls < trans_calls,
             "deterministic (#{det_calls} calls) and transient (#{trans_calls} calls) " <>
               "must not cost the same"
    end
  end

  describe "image.rejected on terminal failure" do
    test "each terminally-failed upload emits exactly one image.rejected event" do
      before_count = event_count("image.rejected")
      branches = all_branches()

      for {_name, response, _kind} <- branches do
        image = insert(:uploaded_image)
        MockClient.clear()
        MockClient.put_response("analyze", response)
        run_attempt(image.id, attempt: 3, max_attempts: 3)
      end

      assert event_count("image.rejected") == before_count + length(branches),
             "every terminal failure must be observable as an image.rejected event"
    end

    test "the event carries the rejection reason the row records" do
      image = insert(:uploaded_image)
      MockClient.put_response("analyze", {:error, {:undecodable_image, "image_too_large"}})

      run_attempt(image.id, attempt: 1, max_attempts: 3)

      row = Repo.get!(UploadedImage, image.id)
      assert row.rejection_reason == "image_too_large"

      event = image_rejected_event_for(image.id)
      assert event, "no image.rejected event was emitted for #{image.id}"
      assert event.payload["reason"] == "image_too_large"
    end
  end

  describe "worst-case lifetime derivation" do
    test "the SSE deadline outlives the job it is waiting on" do
      lifetime = IdentifyBookJob.worst_case_lifetime_ms()

      attempts = 3

      backoffs =
        Enum.sum(for a <- 1..(attempts - 1), do: IdentifyBookJob.backoff(%Oban.Job{attempt: a}))

      assert lifetime == attempts * IdentifyBookJob.attempt_timeout_ms() + backoffs * 1_000

      assert IdentifyBookJob.attempt_timeout_ms() > 2 * AIClient.receive_timeout_ms()
    end

    test "backoff is deterministic, so the sum above is exact" do
      values =
        for _ <- 1..20, do: IdentifyBookJob.backoff(%Oban.Job{attempt: 2})

      assert Enum.uniq(values) == [IdentifyBookJob.backoff(%Oban.Job{attempt: 2})]
    end
  end

  defp run_attempt(image_id, opts, extra_args \\ %{}) do
    args =
      Map.merge(
        %{
          "user_id" => Ecto.UUID.generate(),
          "image_id" => image_id,
          "image_b64" => @image_b64
        },
        extra_args
      )

    perform_job(IdentifyBookJob, args, opts)
  rescue
    exception -> {:raised, exception}
  catch
    kind, reason -> {kind, reason}
  end

  defp drain_counting_calls(image, response) do
    counter = :counters.new(1, [])

    MockClient.clear()

    MockClient.put_response("analyze", fn _payload ->
      :counters.add(counter, 1, 1)
      response
    end)

    {:ok, _job} =
      Oban.insert(
        IdentifyBookJob.new(%{
          "user_id" => Ecto.UUID.generate(),
          "image_id" => image.id,
          "image_b64" => @image_b64
        })
      )

    drained = Oban.drain_queue(queue: :vision, with_scheduled: true, with_recursion: true)

    {:counters.get(counter, 1), drained}
  end

  defp event_count(event_type) do
    Repo.aggregate(
      from(e in "event_log", prefix: "op", where: e.event_type == ^event_type),
      :count
    )
  end

  defp image_rejected_event_for(image_id) do
    {:ok, dumped} = Ecto.UUID.dump(image_id)

    from(e in "event_log",
      prefix: "op",
      where: e.event_type == "image.rejected" and e.aggregate_id == ^dumped,
      select: %{payload: e.payload}
    )
    |> Repo.one()
  end
end
