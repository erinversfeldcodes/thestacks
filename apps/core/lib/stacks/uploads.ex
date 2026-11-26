defmodule Stacks.Uploads do
  @moduledoc """
      The uploaded-image lifecycle: `op.uploaded_images` from creation to a
      terminal state (`awaiting_upload → pending → resolved | rejected`).

      Boundary: this module owns the image ROW and its BYTES — minting,
      proving the bytes landed, enqueueing identify, marking terminal. It does
      NOT own the proto-generated `Stacks.Books.UploadedImage` schema, what the
      pipeline decides (`IdentifyBookJob`/`Moderation`/`Books`), or
      retention/erasure (`GDPR.ImageRetention` + FK cascade). Nothing here knows
      what a book is.
  """

  require Logger

  import Ecto.Changeset
  import Ecto.Query

  alias Core.Repo
  alias Stacks.Books.UploadedImage
  alias Stacks.Events
  alias Stacks.Workers.IdentifyBookJob

  @image_cast_fields [
    :storage_path,
    :status,
    :rejection_reason,
    :uploaded_at,
    :expires_at,
    :book_id,
    :book_edition_id,
    :book_ids,
    :user_id
  ]

  @valid_image_statuses ~w(awaiting_upload pending resolved rejected)

  @min_image_bytes 1_024

  @doc """
      Reads an uploaded file, stores it in object storage, inserts an `UploadedImage`
      record with the `storage_path` set, and returns the record.

      Returns `{:ok, uploaded_image}` or `{:error, reason}`.

      The storage key is persisted on the record so any machine can retrieve the
      image via a presigned URL — no shared filesystem or base64 in job args needed.
  """
  @spec store_upload(binary(), Plug.Upload.t()) ::
          {:ok, UploadedImage.t()} | {:error, term()}
  def store_upload(user_id, %Plug.Upload{path: tmp_path}) do
    image_id = Ecto.UUID.generate()
    storage_key = "uploads/#{image_id}"

    # ⛔ THE ROW IS INSERTED BEFORE THE BYTES, and the order is the whole point.
    # Written the other way round — bytes first, row second — there is a window
    # in which an object exists that no row points at, and an object with no row
    # is reachable by NEITHER erasure (which selects rows by `user_id`) nor the
    # expiry sweep (which selects rows by `expires_at`). That is a right-to-
    # erasure hole, and it is also the window in which
    # `GDPR.ImageRetention.cleanup_orphan_objects/1` would delete a legitimate
    # upload mid-flight.
    #
    # ⚖️ Both orderings can fail; they fail toward different states. Row-first
    # leaves a row with no bytes: reachable by erasure, visible to its owner,
    # and collected by `cleanup_stuck_images/1` within hours. Bytes-first leaves
    # bytes nobody can attribute, erase or expire. Fail toward the reachable
    # state.
    with {:ok, bytes} <- File.read(tmp_path),
         {:ok, image} <- insert_uploaded_image(image_id, storage_key, user_id),
         {:ok, _key} <- Stacks.Storage.upload_image(image_id, bytes) do
      Events.emit_safe(%{
        event_type: "image.submitted",
        aggregate_type: "image",
        aggregate_id: image.id,
        payload: %{storage_path: storage_key}
      })

      {:ok, image}
    else
      {:error, reason} ->
        # Compensate in both directions, and delete the ROW LAST: if that delete
        # is the one that fails, what survives is the reachable half.
        Stacks.Storage.delete_image(storage_key)
        Repo.delete_all(from(i in UploadedImage, where: i.id == ^image_id))
        {:error, reason}
    end
  end

  @doc """
      Write the bytes for a RESERVED upload, for the reader who reserved it.

      ⛔ EVERY CHECK IS HERE, IN THE CONTEXT, and not in the controller. This
      function used to be two lines — `Storage.upload_image(image_id, bytes)` —
      with no lookup of any kind, and `Storage.upload_image/3` interpolates its
      first argument straight into a storage key (`"uploads/\#{image_id}"`). So
      the caller's path segment WAS the key, and nothing established that the
      caller had reserved it, owned it, or that it was a uuid.

      MEASURED on a deployed stack before this change: a `PUT` with no
      credential, an `image_id` of `probe-1793184812-readback`, and 20,361
      bytes of JPEG returned **200**.

      ⚖️ The capability model was sound and simply unimplemented. `init_upload/2`
      mints an unguessable uuid and reserves it for one user, so "holding the
      id" is meant to BE the authorisation — and that only works if the id is
      one we issued. Without that check the capability is not a capability,
      because an id nobody issued is as good as one we did.

      Four refusals, all `:not_found`, and that is deliberate: a caller must not
      be able to tell a malformed id from an unreserved one from somebody
      else's, or the endpoint becomes an oracle for which ids exist.

      ⚠️ `:already_written` is separate because it is NOT an authorisation
      failure — the caller holds a valid capability and has already spent it.
      A reserved id must not be reusable to overwrite an image the pipeline is
      already working on.
  """
  @spec store_upload_bytes(binary(), binary(), binary()) ::
          :ok | {:error, :not_found | :already_written | term()}
  def store_upload_bytes(user_id, image_id, bytes)
      when is_binary(user_id) and is_binary(bytes) do
    with {:ok, uuid} <- cast_reserved_id(image_id),
         {:ok, image} <- fetch_owned_awaiting_upload(user_id, uuid),
         :ok <- refuse_if_already_written(image.storage_path),
         {:ok, _key} <- Stacks.Storage.upload_image(uuid, bytes) do
      :ok
    end
  end

  # ⛔ A non-uuid is refused BEFORE it can reach a storage key, which closes the
  # key-injection and path-traversal question by construction rather than by
  # sanitising. `Path.join` does not normalise `..`, and a `%2F` in the segment
  # decodes to a `/` inside the value — so a check that merely rejected known
  # bad shapes would be a list of the ones somebody thought of.
  defp cast_reserved_id(image_id) do
    case Ecto.UUID.cast(image_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  # The single-write guarantee, asked of the store rather than of a column.
  # "Have the bytes landed" is a fact about the object, and `uploaded_at` cannot
  # answer it — `init_upload/2` sets that at RESERVATION time, before any bytes
  # exist.
  # ⚠️ A HEAD THAT CANNOT BE ANSWERED IS NOT EVIDENCE EITHER WAY, and the third
  # clause is a decision rather than a fall-through. Allowing the write risks
  # overwriting bytes the reader already stored; refusing fails a write that was
  # probably fine. Refusing is the lesser harm — the upload is retryable, an
  # overwrite is not — but it must say so: `:storage_unavailable` becomes a 503,
  # not the 500 that reads as "this endpoint is broken". R2's `head` sits behind
  # a circuit breaker, so `{:error, :circuit_open}` is a routine value here, not
  # an exotic one.
  defp refuse_if_already_written(storage_path) do
    case Stacks.Storage.head_image(storage_path) do
      {:error, :not_found} -> :ok
      {:ok, _size} -> {:error, :already_written}
      {:error, _reason} -> {:error, :storage_unavailable}
    end
  end

  defp insert_uploaded_image(image_id, storage_key, user_id, status \\ "pending") do
    now = DateTime.utc_now()

    %UploadedImage{id: image_id}
    |> uploaded_image_changeset(%{
      storage_path: storage_key,
      status: status,
      uploaded_at: now,
      expires_at: DateTime.add(now, 30, :day),
      user_id: user_id
    })
    |> Repo.insert()
  end

  @doc """
      Init step: allocates `image_id`, reserves the storage key, inserts the row
      as `"awaiting_upload"`, and returns the route the client PUTs the bytes
      to. The client then calls `commit_upload/2`.

      ⛔ **The bytes DO travel through Phoenix, and this docstring said they did
      not.** `upload_url` is `/api/upload/:image_id/data` — a route on our own
      origin, chosen deliberately so the browser never needs an object-storage
      CORS allowlist, and returned as a relative path ever since. The sentence
      that used to stand here ("Bytes never touch Phoenix — the client PUTs
      straight to R2") outlived the design by three months and was then read as
      a premise by the client, which declared the PUT cross-origin and therefore
      sent it with no CSRF proof at all. Every photo upload was refused.

      ⚠️ So `:ttl_seconds` (default 900) is advisory — there is no signature to
      expire. `:content_type` is accepted and recorded; it is not baked into a
      presigned signature, because there is no presigned signature.

      `{:ok, %{image_id, upload_url, expires_in}}` or `{:error, reason}`.
  """
  @spec init_upload(binary(), keyword()) ::
          {:ok, %{image_id: binary(), upload_url: String.t(), expires_in: pos_integer()}}
          | {:error, term()}
  def init_upload(user_id, opts \\ []) do
    image_id = Ecto.UUID.generate()
    storage_key = "uploads/#{image_id}"
    ttl_seconds = Keyword.get(opts, :ttl_seconds, 900)

    upload_url = "/api/upload/#{image_id}/data"

    with {:ok, _image} <-
           insert_uploaded_image(image_id, storage_key, user_id, "awaiting_upload") do
      {:ok, %{image_id: image_id, upload_url: upload_url, expires_in: ttl_seconds}}
    end
  end

  @doc """
      Commit step: HEAD-verifies the client's PUT actually landed (no vision
      work against a missing object), flips the row to `"pending"`, enqueues
      `IdentifyBookJob`. Errors: `:not_found` (no row / not owner),
      `:not_yet_uploaded` (storage HEAD 404 — racing or failed PUT),
      `:already_committed` (idempotent, no re-enqueue), `:image_too_small`
      (under `#{@min_image_bytes}` bytes → rejected via the pipeline's own
      machinery so SSE reports it normally).
  """
  @spec commit_upload(binary(), binary()) ::
          {:ok, %{image_id: binary(), job_id: binary()}} | {:error, term()}
  def commit_upload(user_id, image_id) when is_binary(user_id) and is_binary(image_id) do
    with {:ok, image} <- fetch_owned_awaiting_upload(user_id, image_id),
         :ok <- verify_object_exists(image.storage_path),
         {:ok, updated} <- flip_awaiting_to_pending(image),
         {:ok, job} <- upload_and_identify(user_id, updated.id, updated.storage_path) do
      Events.emit_safe(%{
        event_type: "image.submitted",
        aggregate_type: "image",
        aggregate_id: updated.id,
        payload: %{storage_path: updated.storage_path}
      })

      {:ok, %{image_id: updated.id, job_id: job.id}}
    else
      {:error, :image_too_small} ->
        reject_image(image_id, "image_too_small")
        {:error, :image_too_small}

      other ->
        other
    end
  end

  @doc """
      Marks an in-flight uploaded image (`awaiting_upload` or `pending`) as
      rejected: sets the terminal row state, fires the upload-terminal
      telemetry counter, notifies the SSE stream via PubSub, and emits the
      `image.rejected` event.

      This is THE rejection path — `IdentifyBookJob` delegates here for
      pipeline rejections, and `commit_upload/2` uses it for undersized
      objects — so every rejection is observable the same way. Scoped to
      in-flight statuses so a retry that re-enters after a successful
      rejection cannot re-emit `[:stacks,:upload,:terminal]`.
  """
  @spec reject_image(binary(), String.t()) :: :ok
  def reject_image(image_id, reason) do
    query =
      from(i in UploadedImage,
        where: i.id == ^image_id and i.status in ["awaiting_upload", "pending"]
      )

    {count, _} =
      Repo.update_all(
        query,
        set: [
          status: "rejected",
          rejection_reason: reason,
          updated_at: DateTime.utc_now()
        ]
      )

    if count > 0 do
      Logger.info("Uploads.reject_image: rejected image #{image_id} (#{reason})")

      :telemetry.execute(
        [:stacks, :upload, :terminal],
        %{count: 1},
        %{outcome: :rejected}
      )

      Phoenix.PubSub.broadcast(
        Core.PubSub,
        "upload:#{image_id}",
        {:upload_complete, %{status: "rejected", rejection_reason: reason}}
      )

      Events.emit_safe(%{
        event_type: "image.rejected",
        aggregate_type: "image",
        aggregate_id: image_id,
        payload: %{reason: reason}
      })
    else
      Logger.warning("Uploads.reject_image: image #{image_id} not in-flight, skipping reject")
    end

    :ok
  rescue
    error ->
      Logger.error("Uploads.reject_image: failed to reject image #{image_id}: #{inspect(error)}")
      :ok
  end

  defp verify_object_exists(storage_path) do
    case Stacks.Storage.head_image(storage_path) do
      {:ok, size} when size >= @min_image_bytes -> :ok
      {:ok, _undersized} -> {:error, :image_too_small}
      {:error, :not_found} -> {:error, :not_yet_uploaded}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_owned_awaiting_upload(user_id, image_id) do
    case Repo.get(UploadedImage, image_id) do
      nil ->
        {:error, :not_found}

      %UploadedImage{user_id: owner} when owner != user_id ->
        {:error, :not_found}

      %UploadedImage{status: "awaiting_upload"} = image ->
        {:ok, image}

      %UploadedImage{} ->
        {:error, :already_committed}
    end
  end

  defp flip_awaiting_to_pending(%UploadedImage{} = image) do
    image
    |> uploaded_image_changeset(%{status: "pending"})
    |> Repo.update()
  end

  @doc """
      The uploads this reader started and has not finished with: owned,
      terminal (`resolved`/`rejected` — in-flight rows await the pipeline, not
      the reader), not yet claimed by the 30-day sweep, and still actionable:

      * `resolved` with unshelved candidates → `:awaiting_confirmation`
        (carrying exactly those candidates);
      * `resolved` with every candidate already shelved → dropped (the work is
        done; an inbox that keeps asking is a nag);
      * `resolved` with none, or `rejected` → `:failed` — surfaced because a
        rejection the reader never witnessed is lost work too.
  """
  @spec list_awaiting_attention(binary()) :: [map()]
  def list_awaiting_attention(user_id) when is_binary(user_id) do
    rows =
      from(i in UploadedImage,
        where: i.user_id == ^user_id,
        where: i.status in ["resolved", "rejected"],
        where: i.expires_at > ^DateTime.utc_now(),
        order_by: [desc: i.uploaded_at, desc: i.id]
      )
      |> Repo.all()

    candidate_ids = rows |> Enum.flat_map(&candidate_ids/1) |> Enum.uniq()

    shelved =
      user_id
      |> Stacks.Shelving.shelved_book_ids(candidate_ids)
      |> MapSet.new()

    rows
    |> Enum.map(&inbox_item(&1, shelved))
    |> Enum.reject(&is_nil/1)
  end

  defp candidate_ids(%UploadedImage{book_ids: ids}) when is_list(ids) and ids != [], do: ids
  defp candidate_ids(%UploadedImage{book_id: nil}), do: []
  defp candidate_ids(%UploadedImage{book_id: id}), do: [id]

  defp inbox_item(%UploadedImage{status: "rejected"} = image, _shelved) do
    failed_item(image)
  end

  defp inbox_item(%UploadedImage{status: "resolved"} = image, shelved) do
    case Enum.reject(candidate_ids(image), &MapSet.member?(shelved, &1)) do
      [] ->
        if candidate_ids(image) == [] do
          failed_item(image)
        else
          nil
        end

      unshelved ->
        %{
          image_id: image.id,
          kind: "awaiting_confirmation",
          book_ids: unshelved,
          rejection_reason: nil,
          uploaded_at: image.uploaded_at,
          retryable: retryable?(image)
        }
    end
  end

  # ⛔ FROM THE ROW, NOT FROM A DEADLINE. "No, try again" re-reads the original
  # photograph, and `ImageRetention.cleanup_finished_image_bytes/1` deletes that
  # once identification has been terminal for the reader's retry window — while
  # this record survives to its own 30-day expiry. So for most of an item's life
  # the retry is an action the data cannot support.
  #
  # ⚖️ It asks whether the path is still there, which is the SAME fact
  # `UploadController.reject_identification/2` refuses on. Recomputing "is it
  # within 24 hours" here would express the retention window a second time, and
  # the two would drift the first time it changed — so the window is named in
  # exactly one module and everything else asks the row.
  #
  # ⚠️ THIS IS A CLAIM ABOUT THE ROW, NOT ABOUT THE BYTES, and the difference is
  # measurable rather than theoretical. A row whose object was deleted from the
  # bucket while its `storage_path` still points at it reports `true` here, and
  # the reader is offered a retry that answers 410 — the very thing this field
  # exists to prevent. Production held **2,374 such rows** when it was last
  # measured, and they are not yet remediated.
  #
  # Confirming existence would mean a storage round trip per inbox item on every
  # render, which couples a list endpoint to the backend's latency and
  # availability. So the cheap proxy stands, the 410 remains the backstop, and
  # the honest statement is that this answers "do we still think we have it".
  # `ImageRetention.storage_consistency_check/0` is what detects the disagreeing
  # rows; NULLing their path is what would make this field right about them.
  defp retryable?(%UploadedImage{storage_path: path}),
    do: is_binary(path) and path != ""

  defp failed_item(%UploadedImage{} = image) do
    %{
      image_id: image.id,
      kind: "failed",
      book_ids: [],
      rejection_reason: image.rejection_reason,
      retryable: retryable?(image),
      uploaded_at: image.uploaded_at
    }
  end

  @doc """
      Enqueues a vision-model identification job for an uploaded image.

      The `storage_key` is included in the job args so the worker can fetch a
      presigned URL at execution time — no base64 blob in the job payload.

      Returns `{:ok, job}` immediately; the job resolves ISBN and creates the book asynchronously.
  """
  @spec upload_and_identify(binary(), binary(), String.t()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def upload_and_identify(user_id, image_id, storage_key) do
    %{user_id: user_id, image_id: image_id, storage_key: storage_key}
    |> IdentifyBookJob.new()
    |> Oban.insert()
  end

  @doc false
  def uploaded_image_changeset(image, attrs) do
    image
    |> cast(attrs, @image_cast_fields)
    |> validate_required([:status, :uploaded_at, :expires_at, :user_id])
    |> validate_inclusion(:status, @valid_image_statuses)
  end
end
