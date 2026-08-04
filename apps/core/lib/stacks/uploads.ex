defmodule Stacks.Uploads do
  @moduledoc """
  The uploaded-image lifecycle: `op.uploaded_images` from creation to a
  terminal state.

  An upload row moves through:

      awaiting_upload → client has been issued an upload URL but hasn't yet
        committed. The bytes may or may not be in storage.
      pending         → bytes verified in storage, IdentifyBookJob enqueued.
      resolved        → the identify pipeline matched one or more books.
      rejected        → the pipeline (or `commit_upload/2`'s size floor)
        rejected it.

  ## Boundary (#345)

  This module owns **the image row and its bytes** — minting it, proving the
  bytes landed, handing it to the identify pipeline, and marking it terminal.
  It deliberately does NOT own:

    * the `Stacks.Books.UploadedImage` schema, which is proto-generated and
      stays under `Stacks.Books`;
    * what the pipeline *decides* — `Stacks.Workers.IdentifyBookJob` and
      `Stacks.Moderation` turn an image into books, and `Stacks.Books` mints
      the works and editions. Nothing here knows what a book is;
    * retention/erasure — `Stacks.GDPR.ImageRetention` expires rows and the
      `user_id` FK cascade erases them. Both reach `uploaded_images` through
      the schema, not through this module.

  `upload_and_identify/3` sits on the seam and is kept here on purpose: it
  only *enqueues*, and its one production caller is `commit_upload/2`. The
  decision the job then makes belongs to the job.
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

  # Image lifecycle:
  #   awaiting_upload → client has been issued a presigned PUT URL but
  #     hasn't yet committed. The bytes may or may not be in R2.
  #   pending         → bytes verified in R2, IdentifyBookJob enqueued.
  #   resolved        → pipeline identified one or more books.
  #   rejected        → pipeline rejected (not-a-book, isbn-not-found, etc).
  @valid_image_statuses ~w(awaiting_upload pending resolved rejected)

  # No sub-1KB blob is a real book photo, and each accepted image costs a GPU
  # call — undersized objects are rejected at commit, before vision work exists.
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
        # Clean up stored object if DB insert fails (no-op if upload never happened)
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
  Init step of the presigned-URL upload flow. Allocates an `image_id`,
  reserves the R2 storage key, inserts an `UploadedImage` row with
  status `"awaiting_upload"`, and returns a short-lived presigned PUT
  URL the client uploads to directly.

  Bytes never touch the Phoenix handler — the client PUTs straight to
  R2, then calls `commit_upload/2` to signal completion. Frees the
  HTTP pool during the slow upload transit and removes R2 latency
  from the API response.

  Returns `{:ok, %{image_id: ..., upload_url: ..., expires_in: ...}}`
  or `{:error, reason}` if the row insert or presigning fails.

  `opts` may include:
    * `:content_type` — MIME type hint baked into the presigned URL.
      The client MUST send the matching `Content-Type` header on its
      PUT or R2 rejects with a signature mismatch.
    * `:ttl_seconds` — presigned URL lifetime. Default 900s (15 min).
  """
  @spec init_upload(binary(), keyword()) ::
          {:ok, %{image_id: binary(), upload_url: String.t(), expires_in: pos_integer()}}
          | {:error, term()}
  def init_upload(user_id, opts \\ []) do
    image_id = Ecto.UUID.generate()
    storage_key = "uploads/#{image_id}"
    ttl_seconds = Keyword.get(opts, :ttl_seconds, 900)

    # Use a Phoenix-served upload URL rather than an R2 presigned URL.
    # Direct browser→R2 PUT requires the R2 bucket to allow the request
    # origin in its CORS policy. Preview deployments use *.fly.dev origins
    # which may not be in the bucket allowlist, causing silent CORS failures.
    # Proxying through Phoenix is same-origin from the browser's perspective,
    # so no CORS preflight is needed. Phoenix then stores to the configured
    # backend (R2 in production, Local in dev/preview).
    upload_url = "/api/upload/#{image_id}/data"

    with {:ok, _image} <-
           insert_uploaded_image(image_id, storage_key, user_id, "awaiting_upload") do
      {:ok, %{image_id: image_id, upload_url: upload_url, expires_in: ttl_seconds}}
    end
  end

  @doc """
  Commit step of the presigned-URL upload flow. Verifies the client's
  direct PUT to R2 actually landed, flips the `UploadedImage` row from
  `"awaiting_upload"` to `"pending"`, and enqueues `IdentifyBookJob`.

  The HEAD check prevents a client from calling commit without actually
  uploading — we won't enqueue vision work against a missing object.

  Returns `{:ok, %{image_id: ..., job_id: ...}}` on success, or:
    * `{:error, :not_found}` — no such upload row, or the client's
      user_id doesn't own it.
    * `{:error, :not_yet_uploaded}` — row exists and is owned, but R2
      HEAD returned 404. Either the client is racing the commit before
      their PUT completed, or the upload failed silently.
    * `{:error, :already_committed}` — row status is already `"pending"`
      or a terminal state. Idempotent — repeat commits are safe but
      don't re-enqueue.
    * `{:error, :image_too_small}` — the object landed but is under
      `#{@min_image_bytes}` bytes, which no real book photo is. The row is
      marked rejected via the same machinery the identify pipeline uses,
      so the SSE stream reports it as an ordinary rejection.
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
        # The same rejection path an invalid image takes downstream: terminal
        # row state + SSE notification + image.rejected event — never a bare
        # error the client would be told to retry.
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
  rejection cannot re-emit `[:stacks, :upload, :terminal]`.
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

  # Translate the storage backend's :not_found into :not_yet_uploaded so
  # the controller can distinguish "no such row" from "row exists but
  # the client PUT hasn't landed yet" — the latter is a race condition
  # clients can retry, the former is a hard 404.
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
  The uploads this reader started and has not finished with (#351).

  ## The predicate, stated

  An upload is *awaiting attention* when all of the following hold:

    * it belongs to this reader;
    * it has reached a terminal status — `resolved` or `rejected`. An
      in-flight row is not awaiting the reader, it is awaiting the pipeline,
      and `IdentifyBookJob`'s terminal guarantee (#342) says it will get there;
    * the 30-day retention sweep has not already claimed it
      (`expires_at > now`). A row past its expiry is about to be deleted;
      listing it would offer the reader work that is going to vanish;
    * **and** there is still something for a human to do with it:
        * `resolved` with at least one candidate the reader has NOT shelved by
          some other route → `:awaiting_confirmation`, carrying exactly those
          unshelved candidates;
        * `resolved` with every candidate already shelved → **dropped**. The
          reader typed the ISBN in, or photographed it again, or confirmed it
          in another tab. The work is done; an inbox that keeps asking is a
          nag, not a reminder;
        * `resolved` with no candidates at all, or `rejected` → `:failed`.

  ## Why failures are here but are not confirmations

  A `rejected` upload the reader never witnessed is lost work too — today they
  simply never learn, because the only place a rejection was ever rendered was
  a page they had already left. So it is surfaced. It is a *different kind*,
  and the caller must keep it that way: a failure has nothing to confirm and
  nothing to place, and counting it as a pending confirmation would put a
  number on the navigation badge that no action can ever clear.

  ⚠️ **This function places nothing and can place nothing.** It reads
  `uploaded_images` and `bookshelf_placements` and returns maps. Every route
  from an inbox item to a shelf runs through the reader's existing
  confirm → choose-shelf → place flow.

  Newest first. Two queries regardless of how many items there are.
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

    # ⚠️ `MapSet.new/1` is called HERE, not in `Shelving`, and that placement is the fix for an OTP 28
    # dialyzer failure rather than a style choice. `MapSet.t/1` is opaque; dialyzer's success typing
    # sees through the producing function to a structural `%MapSet{map: ...}`, and passing that across
    # a module boundary into `MapSet.member?/2` is `call_without_opaque`. Building the set in the same
    # module that queries it keeps the opacity from ever travelling. Same class as b76fa3f3.
    candidate_ids = rows |> Enum.flat_map(&candidate_ids/1) |> Enum.uniq()

    shelved =
      user_id
      |> Stacks.Shelving.shelved_book_ids(candidate_ids)
      |> MapSet.new()

    rows
    |> Enum.map(&inbox_item(&1, shelved))
    |> Enum.reject(&is_nil/1)
  end

  # `book_ids` is the multi-candidate array; `book_id` is the single-match
  # column the pipeline wrote before the array existed. The SSE stream prefers
  # the array and falls back to the singleton, and so must this — otherwise an
  # older resolved row is an inbox item with nothing in it.
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
          # Resolved with nothing identified. The reader is owed the news, and
          # the client's `CauseUnknown` copy is the honest one: we cannot say
          # why, and a nil token asks for exactly that sentence.
          failed_item(image)
        else
          # Every candidate is already on a bookshelf — finished, by whatever
          # route. This is the branch that stops the inbox nagging.
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
