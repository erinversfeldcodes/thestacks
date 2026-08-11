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

    with {:ok, bytes} <- File.read(tmp_path),
         {:ok, _key} <- Stacks.Storage.upload_image(image_id, bytes),
         {:ok, image} <- insert_uploaded_image(image_id, storage_key, user_id) do
      Events.emit_safe(%{
        event_type: "image.submitted",
        aggregate_type: "image",
        aggregate_id: image.id,
        payload: %{storage_path: storage_key}
      })

      {:ok, image}
    else
      {:error, reason} ->
        Stacks.Storage.delete_image(storage_key)
        {:error, reason}
    end
  end

  @doc """
    Store raw image bytes for an upload initiated via `init_upload/2`.

    Called by `UploadController.upload_data/2` when the browser PUTs file bytes
    to the Phoenix-proxied upload endpoint. Returns `:ok` on success.
  """
  @spec store_upload_bytes(binary(), binary()) :: :ok | {:error, term()}
  def store_upload_bytes(image_id, bytes) when is_binary(bytes) do
    case Stacks.Storage.upload_image(image_id, bytes) do
      {:ok, _key} -> :ok
      {:error, reason} -> {:error, reason}
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
    Init step of the presigned-URL flow: allocates `image_id`, reserves the
    R2 key, inserts the row as `"awaiting_upload"`, returns a short-lived
    presigned PUT URL. Bytes never touch Phoenix — the client PUTs straight to
    R2, then calls `commit_upload/2`.

    Options: `:content_type` (client MUST send the matching header on its PUT
    or R2 rejects the signature) and `:ttl_seconds` (default 900).
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
    `:not_yet_uploaded` (R2 HEAD 404 — racing or failed PUT),
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
          uploaded_at: image.uploaded_at
        }
    end
  end

  defp failed_item(%UploadedImage{} = image) do
    %{
      image_id: image.id,
      kind: "failed",
      book_ids: [],
      rejection_reason: image.rejection_reason,
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
