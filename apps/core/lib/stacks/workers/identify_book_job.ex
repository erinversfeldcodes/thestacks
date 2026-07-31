defmodule Stacks.Workers.IdentifyBookJob do
  @moduledoc """
  Oban worker that processes an uploaded image through the Modal vision service
  to identify and create/update a book record.

  New jobs receive a `storage_key` in args and fetch a presigned URL at execution
  time. Legacy in-flight jobs that still carry `image_b64` are handled via
  backwards-compatible pattern matching.

  ## The terminal guarantee

  **No exit from this worker may leave the `uploaded_images` row `pending`.**
  Every return, every raise, every exit, on every attempt, passes through
  `with_terminal_guarantee/3`; when the job has no attempts left, the row is
  marked rejected and the reader's SSE stream is closed with a real answer.

  This is written as a wrapper and not as a fix to the branch that was known to
  be broken, because the shape of the bug is what recurs. There were two live
  instances of it when this was written and they looked nothing alike: a generic
  `{:error, reason}` that retried to exhaustion and then simply stopped, and an
  unrecognised `/analyze` body that raised `CaseClauseError` into a rescue. In
  both, the reader watched a spinner until the SSE deadline expired, minutes
  after the job was dead. A wrapper covers the branch nobody has written yet.

  `Stacks.Books.reject_image/2` is idempotent and scoped to in-flight rows, so
  applying it broadly is safe: a row that already reached `resolved` is not
  touched, and a second call on a rejected row is a no-op.
  """

  use Oban.Worker, queue: :vision, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Core.Repo
  alias Stacks.AI.VisionError
  alias Stacks.Books.UploadedImage
  alias Stacks.Events
  alias Stacks.Moderation
  alias Stacks.Storage

  @max_attempts 3

  # Ceiling on ONE attempt. Set so the worst-case lifetime is a number rather
  # than "however long Modal feels like taking": `Stacks.AI.Client` gives Finch a
  # 210s receive timeout and `Stacks.Moderation` bounds its candidate tasks at
  # the same 210s, so 240s is that ceiling plus room for the surrounding DB work.
  # Without this, `worst_case_lifetime_ms/0` below would be a guess, and the
  # reader's give-up time would be a guess about a guess.
  @attempt_timeout_ms 240_000

  # ── Retry schedule ────────────────────────────────────────────────────────

  @doc """
  Seconds to wait before the next attempt.

  Deliberately deterministic, where `Oban.Worker`'s default adds up to 10%
  jitter. Jitter exists to desynchronise a thundering herd of jobs retrying
  together; one job per upload is not that, and what we get in exchange is a
  retry schedule whose total is exactly computable — which is what lets
  `worst_case_lifetime_ms/0` state when this job is certainly dead instead of
  approximating it. The curve itself matches Oban's default (15s pad, doubling).
  """
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: 15 + Integer.pow(2, attempt)

  @doc """
  Hard timeout for a single attempt. See `@attempt_timeout_ms`.
  """
  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: @attempt_timeout_ms

  @doc """
  The longest this job can stay alive, in milliseconds, from first attempt to
  the moment its last attempt can no longer be running.

  Every attempt runs at most `timeout/1`, and every gap between attempts is
  exactly `backoff/1` — so this is a sum, not an estimate. It exists so the
  reader's SSE deadline can be *derived* from when the job actually dies rather
  than picked to sit near it: see `StacksWeb.UploadController`.
  """
  @spec worst_case_lifetime_ms() :: pos_integer()
  def worst_case_lifetime_ms do
    backoff_ms =
      Enum.sum(for attempt <- 1..(@max_attempts - 1), do: backoff(%Oban.Job{attempt: attempt})) *
        1_000

    @max_attempts * @attempt_timeout_ms + backoff_ms
  end

  # ── Entry point ───────────────────────────────────────────────────────────

  # One head, so that args matching NO dispatch clause is a value this module
  # decides about rather than a FunctionClauseError raised before the guarantee
  # is in scope.
  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    with_terminal_guarantee(job, Map.get(args, "image_id"), fn -> dispatch(job) end)
  end

  # ── New path: storage_key ─────────────────────────────────────────────────

  defp dispatch(%Oban.Job{
         args:
           %{"user_id" => user_id, "image_id" => image_id, "storage_key" => storage_key} = args
       }) do
    Logger.info("IdentifyBookJob: processing image #{image_id} for user #{user_id}")

    case Storage.get_image_url(storage_key) do
      {:ok, image_url} ->
        context =
          %{
            image_url: image_url,
            user_id: user_id,
            image_id: image_id
          }
          |> put_excluded_books(args)
          |> put_excluded_isbns(args)

        run_pipeline(context, image_id)

      {:error, reason} ->
        Logger.error(
          "IdentifyBookJob: failed to get presigned URL for #{storage_key}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # ── Legacy path: image_b64 (backwards compat for in-flight jobs) ──────────

  defp dispatch(%Oban.Job{
         args: %{"user_id" => user_id, "image_id" => image_id, "image_b64" => image_b64} = args
       }) do
    Logger.info(
      "IdentifyBookJob: processing image #{image_id} for user #{user_id} (legacy b64 path)"
    )

    context =
      %{
        image_b64: image_b64,
        user_id: user_id,
        image_id: image_id
      }
      |> put_excluded_books(args)
      |> put_excluded_isbns(args)

    run_pipeline(context, image_id)
  end

  # Args that name neither an image source nor (possibly) an image at all. A
  # retry would present the identical args, so this cancels immediately; the
  # wrapper still marks the row, when there is a row to mark.
  defp dispatch(%Oban.Job{args: args}) do
    Logger.error(
      "IdentifyBookJob: job args match no dispatch clause " <>
        "(keys: #{inspect(args |> Map.keys() |> Enum.sort())})"
    )

    {:cancel, "malformed job args"}
  end

  # Carries the cumulative rejected-books list from the args map into the
  # moderation context. Missing or non-list values are normalised to an
  # empty list so downstream callers can `Map.get(context, :excluded_books, [])`
  # without worrying about shape.
  defp put_excluded_books(context, args) do
    case Map.get(args, "excluded_books") do
      list when is_list(list) -> Map.put(context, :excluded_books, list)
      _ -> context
    end
  end

  # Carries the cumulative rejected-ISBNs list from the args map into the
  # moderation context. The resolver layer consumes this to skip OL/GB
  # search hits whose ISBN matches a previously-rejected book, preventing
  # a slightly-different VLM title variant from collapsing back to the
  # same wrong ISBN on every retry. Distinct from `excluded_books` (which
  # is VLM-bound for the extract prompt) — this list is Elixir-side only.
  defp put_excluded_isbns(context, args) do
    case Map.get(args, "excluded_isbns") do
      list when is_list(list) -> Map.put(context, :excluded_isbns, list)
      _ -> context
    end
  end

  # ── The terminal guarantee ────────────────────────────────────────────────

  # Runs the job body and, if this attempt is the job's last, ensures the image
  # row is left in a terminal state before the result escapes.
  #
  # Only the wrapper writes rejections. The body says WHAT happened
  # (`{:reject, token, message}` for a determination, `{:error, reason}` for a
  # fault) and the wrapper decides whether that ends the job — because only the
  # wrapper knows the attempt number, and "is this the last attempt" is exactly
  # the fact the branch sites kept not having.
  #
  # Raises are caught, marked, and re-raised rather than converted to
  # `{:error, exception}`: Oban records the kind, reason and stacktrace of a
  # raised error, and flattening it into a return value threw that away. The row
  # is terminal either way; this way the operator can also see why.
  defp with_terminal_guarantee(job, image_id, body) do
    result = body.()
    finalise(job, image_id, result)
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__

      Logger.error(
        "IdentifyBookJob: unhandled #{kind} for image #{inspect(image_id)}: " <>
          Exception.format(kind, reason, stacktrace)
      )

      if final_attempt?(job), do: mark_rejected(image_id, "processing_failed")
      :erlang.raise(kind, reason, stacktrace)
  end

  # Translates the body's vocabulary into Oban's, marking the row on the way
  # through. Written without a catch-all: a new body outcome must be classified
  # here, and the compiler says so.
  defp finalise(_job, _image_id, :ok), do: :ok

  defp finalise(_job, image_id, {:reject, token, message}) do
    mark_rejected(image_id, token)
    {:cancel, message}
  end

  # A cancel decided outside the pipeline (malformed args). There is no
  # determination token to carry, so the row records the generic one — and
  # `image_id` may itself be missing, which is one of the ways args get
  # malformed.
  defp finalise(_job, nil, {:cancel, message}), do: {:cancel, message}

  defp finalise(_job, image_id, {:cancel, message}) do
    mark_rejected(image_id, "processing_failed")
    {:cancel, message}
  end

  defp finalise(job, image_id, {:error, reason}) do
    if final_attempt?(job) do
      Logger.error(
        "IdentifyBookJob: image #{inspect(image_id)} exhausted #{job.max_attempts} attempts; " <>
          "last error: #{inspect(reason)}"
      )

      mark_rejected(image_id, rejection_token(reason))
    end

    {:error, reason}
  end

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max_attempts}),
    do: attempt >= max_attempts

  # A failure that came from the vision service names its own reader-facing
  # token; anything else (a storage presign failure, a raised exception, a
  # reason a test double invented) is a fault we cannot describe more precisely
  # than "we could not process this".
  defp rejection_token(reason) do
    if VisionError.vision_error?(reason) do
      VisionError.reason_token(reason)
    else
      "processing_failed"
    end
  end

  # ── Pipeline ──────────────────────────────────────────────────────────────

  defp run_pipeline(context, image_id) do
    Stacks.Telemetry.phase(:identify_book, %{upload_id: image_id}, fn ->
      do_run_pipeline(context, image_id)
    end)
  end

  defp do_run_pipeline(context, image_id) do
    case Moderation.run_pipeline(context) do
      {:ok, %{resolved: books, rejected: rejected}} when is_list(books) ->
        book_ids = Enum.map(books, & &1.id)
        isbns = Enum.map_join(books, ", ", &primary_isbn/1)

        Logger.info("IdentifyBookJob: identified #{length(books)} book(s): #{isbns}")
        mark_resolved(image_id, book_ids)
        emit_partial_rejections(image_id, rejected)
        :ok

      {:error, :not_a_book} ->
        Logger.warning("IdentifyBookJob: image #{image_id} is not a book")
        {:reject, "not_a_book", "image does not contain a book"}

      {:error, :isbn_not_found} ->
        Logger.warning("IdentifyBookJob: could not extract ISBN from image #{image_id}")
        {:reject, "isbn_not_found", "isbn_not_found"}

      {:error, reason} ->
        Logger.error("IdentifyBookJob: pipeline failed: #{inspect(reason)}")
        classify_failure(reason)
    end
  end

  # The retry decision, made from the failure's KIND rather than its shape.
  #
  # A deterministic vision error is a conclusion about these bytes: the service
  # has already looked and told us it cannot read them. Sending them again buys
  # nothing and costs the reader the full backoff schedule, so it cancels on the
  # first attempt. Everything else may succeed next time and is returned as an
  # error for Oban to retry — with the wrapper above guaranteeing that "next
  # time" eventually runs out into a terminal row rather than into silence.
  defp classify_failure(reason) do
    if VisionError.vision_error?(reason) and
         VisionError.determination(reason) == :deterministic do
      {:reject, VisionError.reason_token(reason), VisionError.message(reason)}
    else
      {:error, reason}
    end
  end

  # Emits one `image.rejected` event per failed candidate from a
  # multi-book partial-resolve. The aggregate_id stays the same `image_id`
  # so the events tie back to the upload — observability tools can group
  # by aggregate to reconstruct the per-image outcome (1+ resolved + N
  # rejected). The image's row stays `resolved` because at least one
  # candidate succeeded; that's the all-or-nothing rejection contract at
  # the upload level.
  defp emit_partial_rejections(_image_id, []), do: :ok

  defp emit_partial_rejections(image_id, rejected) when is_list(rejected) do
    Enum.each(rejected, fn {candidate_id, reason} ->
      Events.emit_safe(%{
        event_type: "image.rejected",
        aggregate_type: "image",
        aggregate_id: image_id,
        payload: %{
          isbn: to_string(candidate_id),
          reason: to_string(reason)
        }
      })
    end)
  end

  defp primary_isbn(%{editions: [edition | _]}), do: edition.isbn
  defp primary_isbn(_book), do: "unknown"

  defp mark_resolved(image_id, book_ids) when is_list(book_ids) do
    # Scope the update to rows still in `pending` so Oban retries that re-enter
    # this path after a successful run do not re-touch the row and double-emit
    # the [:stacks, :upload, :terminal] telemetry event. Only a real
    # pending -> resolved transition fires the counter.
    query = from(i in UploadedImage, where: i.id == ^image_id and i.status == "pending")

    {count, _} =
      Repo.update_all(
        query,
        set: [
          status: "resolved",
          book_id: List.first(book_ids),
          book_ids: book_ids,
          updated_at: DateTime.utc_now()
        ]
      )

    if count > 0 do
      Logger.info("IdentifyBookJob: resolved image #{image_id} → #{length(book_ids)} book(s)")

      :telemetry.execute(
        [:stacks, :upload, :terminal],
        %{count: 1},
        %{outcome: :resolved}
      )

      Phoenix.PubSub.broadcast(
        Core.PubSub,
        "upload:#{image_id}",
        {:upload_complete, %{status: "resolved", book_ids: book_ids}}
      )

      Events.emit_safe(%{
        event_type: "image.resolved",
        aggregate_type: "image",
        aggregate_id: image_id,
        payload: %{book_count: length(book_ids)}
      })
    else
      Logger.warning("IdentifyBookJob: image #{image_id} not found for resolve")
    end
  rescue
    error ->
      Logger.error("IdentifyBookJob: failed to resolve image #{image_id}: #{inspect(error)}")
  end

  # Rejection machinery lives in `Stacks.Books.reject_image/2` (terminal row
  # state + telemetry + SSE PubSub + image.rejected event) so the commit-time
  # undersized-object gate and this pipeline share one observable path.
  defp mark_rejected(image_id, reason), do: Stacks.Books.reject_image(image_id, reason)
end
