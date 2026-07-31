defmodule StacksWeb.UploadController do
  @moduledoc "Handles image uploads and enqueues identification jobs."

  use CoreWeb, :controller

  require Logger

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Accounts.Guardian
  alias Stacks.Books
  alias Stacks.Books.TitleSearchCache
  alias Stacks.Books.UploadedImage
  alias Stacks.Shelving
  alias Stacks.Uploads
  alias Stacks.Workers.IdentifyBookJob
  alias StacksWeb.ProtoJSON

  @doc """
  POST /api/upload/init — first step of the presigned-URL upload flow.

  Body: `{content_type: "image/jpeg"}` (optional, defaults to image/jpeg).

  Returns: `{image_id, upload_url, expires_in}`. Client PUTs the image
  bytes directly to `upload_url` (R2), then calls
  `POST /api/upload/:id/commit` to signal completion. Phoenix never
  sees the bytes — the POST here is a lightweight DB insert + local
  SigV4 signing operation (~50ms typical).
  """
  @spec init(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def init(conn, params) do
    user = Guardian.Plug.current_resource(conn)
    content_type = Map.get(params, "content_type", "image/jpeg")

    case Uploads.init_upload(user.id, content_type: content_type) do
      {:ok, %{image_id: image_id, upload_url: url, expires_in: expires_in}} ->
        conn
        |> put_status(201)
        |> json(%{image_id: image_id, upload_url: url, expires_in: expires_in})

      {:error, _reason} ->
        conn
        |> put_status(500)
        |> json(%{error: "init_failed"})
    end
  end

  @doc """
  POST /api/upload/:image_id/commit — second step of the presigned-URL
  flow. Verifies that the client's direct PUT to R2 landed (HEAD),
  flips the row from `awaiting_upload` to `pending`, and enqueues
  `IdentifyBookJob`. The SSE stream endpoint works against the
  resulting row exactly as before.
  """
  @spec commit(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def commit(conn, %{"image_id" => image_id}) do
    user = Guardian.Plug.current_resource(conn)

    case Uploads.commit_upload(user.id, image_id) do
      {:ok, %{image_id: id, job_id: _}} ->
        conn
        |> put_status(202)
        |> json(%{status: "accepted", image_id: id})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, :not_yet_uploaded} ->
        conn |> put_status(409) |> json(%{error: "not_yet_uploaded"})

      {:error, :already_committed} ->
        conn |> put_status(409) |> json(%{error: "already_committed"})

      {:error, :image_too_small} ->
        # The PUT landed but the object cannot be a real book photo. The row
        # has already been marked rejected, so the SSE stream reports it like
        # any other rejection — 422, not a retryable 5xx.
        conn |> put_status(422) |> json(%{error: "image_too_small"})

      {:error, _reason} ->
        conn |> put_status(500) |> json(%{error: "commit_failed"})
    end
  end

  @doc """
  PUT /api/upload/:image_id/data — receive file bytes for the init/commit upload flow.

  No authentication: the image_id UUID (128-bit random) is effectively unguessable,
  and `commit_upload` verifies ownership before enqueuing work. Phoenix stores the
  bytes via the configured storage backend (R2 in production, Local in dev/preview).
  """
  @spec upload_data(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def upload_data(conn, %{"image_id" => image_id}) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 20_971_520)

    case Uploads.store_upload_bytes(image_id, body) do
      :ok ->
        send_resp(conn, 200, "")

      {:error, reason} ->
        Logger.error(
          "UploadController.upload_data: storage failed for #{image_id}: #{inspect(reason)}"
        )

        conn |> put_status(500) |> json(%{error: "storage_failed"})
    end
  end

  @doc """
  POST /api/upload/:image_id/reject-identification — user clicked
  "No, try again" on the model's guess.

  Accepts a cumulative `rejected_book_ids` list (the frontend keeps
  state; the server is stateless w.r.t. this list). The action:

    1. Verifies the caller owns the upload row.
    2. Resolves each book_id to a "Title by Author" string AND to its
       primary edition's ISBN via `Stacks.Books.get_book_detail/1`.
       Unresolvable IDs are skipped; if the resolved descriptor list is
       empty, returns 422.
    3. Removes any active placement the user holds for the rejected
       book(s) so the retry can place a fresh one. Soft-delete via
       `Stacks.Shelving.remove_book/2`. Missing placements are a no-op.
    3b. Invalidates `Stacks.Books.TitleSearchCache` entries for EVERY
       edition ISBN of each rejected book — the memoised title-search
       result that produced the wrong pick would otherwise keep winning
       round 1 of any fresh upload of the same image for up to 24 h.
       Best-effort: a failure here logs a warning but never fails the 202.
    4. Enqueues a fresh `IdentifyBookJob` with both `excluded_books`
       (strings, steer the VLM) and `excluded_isbns` (strings, steer the
       resolver away from previously-returned matches at the title-search
       layer).

  Returns 202 `{status: "pending", excluded_books: [...]}` on success.
  Returns 401 without auth (handled by AuthPipeline).
  Returns 404 when the upload doesn't belong to the caller (or is missing).
  Returns 422 when no rejected_book_ids resolve to a known book.
  """
  @spec reject_identification(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reject_identification(conn, %{"image_id" => image_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    rejected_ids = Map.get(params, "rejected_book_ids", [])

    with {:ok, image} <- fetch_owned_image(image_id, user.id),
         excluded when excluded != [] <- resolve_excluded_books(rejected_ids) do
      excluded_isbns = resolve_excluded_isbns(rejected_ids)
      remove_placements_for_books(user.id, rejected_ids)
      invalidate_title_search_cache(rejected_ids)
      {:ok, _job} = enqueue_retry(user.id, image, excluded, excluded_isbns)

      conn
      |> put_status(202)
      |> json(%{status: "pending", excluded_books: excluded})
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      [] ->
        conn
        |> put_status(422)
        |> json(%{error: "no_resolvable_books"})
    end
  end

  defp fetch_owned_image(image_id, user_id) do
    case Ecto.UUID.cast(image_id) do
      {:ok, uuid} ->
        case Repo.get(UploadedImage, uuid) do
          nil -> {:error, :not_found}
          %UploadedImage{user_id: owner} when owner != user_id -> {:error, :not_found}
          %UploadedImage{} = image -> {:ok, image}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp resolve_excluded_books(book_ids) when is_list(book_ids) do
    book_ids
    |> Enum.uniq()
    |> Enum.map(&book_descriptor/1)
    |> Enum.reject(&is_nil/1)
  end

  defp resolve_excluded_books(_), do: []

  # Resolve the cumulative rejected_book_ids list to the primary edition
  # ISBN for each book. These ISBNs are forwarded as `excluded_isbns` to
  # the IdentifyBookJob → Moderation → ISBNResolver so the resolver layer
  # can skip OL/GB search results whose ISBN matches a rejected book —
  # without this, a slightly-different VLM title variant can collapse to
  # the same wrong ISBN on every retry.
  defp resolve_excluded_isbns(book_ids) when is_list(book_ids) do
    book_ids
    |> Enum.uniq()
    |> Enum.map(&book_primary_isbn/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp resolve_excluded_isbns(_), do: []

  defp book_descriptor(book_id) when is_binary(book_id) do
    case Ecto.UUID.cast(book_id) do
      {:ok, uuid} -> describe_book(Books.get_book_detail(uuid))
      :error -> nil
    end
  end

  defp book_descriptor(_), do: nil

  defp book_primary_isbn(book_id) when is_binary(book_id) do
    case Ecto.UUID.cast(book_id) do
      {:ok, uuid} -> extract_primary_isbn(Books.get_book_detail(uuid))
      :error -> nil
    end
  end

  defp book_primary_isbn(_), do: nil

  defp extract_primary_isbn(nil), do: nil

  defp extract_primary_isbn(%{} = book) do
    case Books.primary_edition(book) do
      %{isbn: isbn} when is_binary(isbn) and isbn != "" -> isbn
      _ -> nil
    end
  end

  defp describe_book(nil), do: nil

  defp describe_book(%{title: title} = book) when is_binary(title) and title != "" do
    case book.author do
      %{name: name} when is_binary(name) and name != "" -> "#{title} by #{name}"
      _ -> title
    end
  end

  defp describe_book(_), do: nil

  # Kill the poisoned title-search memo(s) for the rejected book(s).
  # Uses ALL edition ISBNs (not just the primary) so an entry cached
  # against any edition of the rejected work is invalidated too.
  # Best-effort by design: cache invalidation failing must not fail the
  # user-facing 202 — the retry job carries excluded_isbns and bypasses
  # the cache regardless; this protects the FIRST round of future uploads.
  defp invalidate_title_search_cache(book_ids) when is_list(book_ids) do
    book_ids
    |> Enum.uniq()
    |> Enum.flat_map(&book_edition_isbns/1)
    |> Enum.uniq()
    |> Enum.each(&TitleSearchCache.invalidate_by_isbn/1)
  rescue
    error ->
      Logger.warning(
        "reject_identification: TitleSearchCache invalidation failed: #{inspect(error)}"
      )

      :ok
  end

  defp invalidate_title_search_cache(_), do: :ok

  defp book_edition_isbns(book_id) when is_binary(book_id) do
    case Ecto.UUID.cast(book_id) do
      {:ok, uuid} -> extract_edition_isbns(Books.get_book_detail(uuid))
      :error -> []
    end
  end

  defp book_edition_isbns(_), do: []

  defp extract_edition_isbns(%{editions: editions}) when is_list(editions) do
    editions
    |> Enum.map(& &1.isbn)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp extract_edition_isbns(_), do: []

  # Decision (#333): undo exactly ONE placement — the most recent — not all of
  # them.
  #
  # This is the reject-identification path: the reader is saying "that book was
  # never in my photo", so we withdraw what the identification put on a shelf.
  # Under the owner's multi-shelf ruling that book may legitimately sit on
  # several bookshelves, and the other placements are ones the reader made
  # deliberately — removing them would be destroying their data to undo our
  # mistake. The identification's own placement was created last, so the newest
  # active placement is the one to withdraw.
  #
  # "Newest" is a heuristic, not provenance: if the reader shelved the book by
  # hand in the seconds between identification and rejection, the newest is
  # theirs. The honest fix is a provenance column on the placement, which is
  # #335's scope (`verification_source`) — until then, undoing one placement is
  # the conservative error: an extra shelf entry the reader can remove beats a
  # deliberate one we deleted for them.
  defp remove_placements_for_books(user_id, book_ids) do
    Enum.each(book_ids, fn book_id ->
      with {:ok, uuid} <- Ecto.UUID.cast(book_id),
           %{id: placement_id} <- List.last(Shelving.get_placements_for_book(user_id, uuid)) do
        Shelving.remove_book(placement_id, user_id)
      end
    end)
  end

  defp enqueue_retry(user_id, image, excluded_books, excluded_isbns) do
    args =
      %{
        "user_id" => user_id,
        "image_id" => image.id,
        "excluded_books" => excluded_books,
        "excluded_isbns" => excluded_isbns
      }
      |> maybe_put_storage_key(image.storage_path)

    args
    |> IdentifyBookJob.new()
    |> Oban.insert()
  end

  defp maybe_put_storage_key(args, nil), do: args
  defp maybe_put_storage_key(args, ""), do: args
  defp maybe_put_storage_key(args, path), do: Map.put(args, "storage_key", path)

  @doc "GET /api/upload/:image_id/stream — stream SSE status updates for an uploaded image."
  @spec stream(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def stream(conn, %{"image_id" => image_id}) do
    case Ecto.UUID.cast(image_id) do
      {:ok, uuid} -> render_stream(conn, uuid)
      :error -> conn |> put_status(400) |> json(%{error: "invalid image_id"})
    end
  end

  defp render_stream(conn, image_id) do
    user = Guardian.Plug.current_resource(conn)

    # Subscribe to PubSub BEFORE reading DB status to avoid race condition
    Phoenix.PubSub.subscribe(Core.PubSub, "upload:#{image_id}")

    result =
      from(i in UploadedImage,
        where: i.id == ^image_id,
        select: %{
          status: i.status,
          book_id: i.book_id,
          book_ids: i.book_ids,
          rejection_reason: i.rejection_reason,
          user_id: i.user_id
        }
      )
      |> Repo.one()

    case result do
      nil ->
        Phoenix.PubSub.unsubscribe(Core.PubSub, "upload:#{image_id}")
        conn |> put_status(404) |> json(%{error: "not found"})

      %{user_id: owner_id} when not is_nil(owner_id) and owner_id != user.id ->
        Phoenix.PubSub.unsubscribe(Core.PubSub, "upload:#{image_id}")
        conn |> put_status(403) |> json(%{error: "forbidden"})

      %{
        status: status,
        book_id: book_id_bin,
        book_ids: book_ids_bins,
        rejection_reason: rejection_reason
      } ->
        book_id_str = decode_uuid(book_id_bin)
        book_ids_strs = decode_uuid_list(book_ids_bins)
        effective_ids = effective_book_ids(book_ids_strs, book_id_str)
        is_duplicate = Enum.any?(effective_ids, &Shelving.book_on_any_shelf?(user.id, &1))

        payload =
          ProtoJSON.poll_response(%{
            image_id: image_id,
            status: status,
            book_id: book_id_str,
            book_ids: effective_ids,
            rejection_reason: rejection_reason,
            is_duplicate: is_duplicate
          })

        if status in ["resolved", "rejected"] do
          Phoenix.PubSub.unsubscribe(Core.PubSub, "upload:#{image_id}")
          send_sse_event(conn, payload)
        else
          stream_sse(conn, image_id, payload, user)
        end
    end
  end

  defp send_sse_event(conn, payload) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "data: #{Jason.encode!(payload)}\n\n")
    conn
  end

  defp stream_sse(conn, image_id, _initial_payload, user) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    deadline = System.monotonic_time(:millisecond) + sse_max_timeout_ms()
    sse_receive_loop(conn, image_id, user, deadline)
  end

  # How long to hold the stream open before telling the reader we gave up.
  #
  # Derived from the job, not chosen to sit near it. `IdentifyBookJob` bounds
  # every attempt with `timeout/1` and every gap with a deterministic
  # `backoff/1`, so `worst_case_lifetime_ms/0` is the exact moment after which
  # the job cannot still be working — and the job's final-attempt wrapper
  # guarantees that by then the row is terminal and a result has been broadcast.
  # Waiting for it is therefore waiting for an answer that is coming, and
  # stopping earlier means reporting a timeout to a reader whose book is about
  # to be identified. That was the old failure in both directions: the hardcoded
  # 360s both outlived a job that had already died silently (the reader watched
  # a spinner for six minutes after the fact) and expired while a slow job was
  # still alive.
  #
  # `+ 5s` covers the marking and broadcast that happen after the last attempt
  # returns. The `:sse_max_timeout_ms` key remains an override for tests, which
  # need a deadline measured in milliseconds; setting it in a deployed
  # environment re-introduces the divergence this derivation removes.
  defp sse_max_timeout_ms do
    Application.get_env(:core, :sse_max_timeout_ms) ||
      IdentifyBookJob.worst_case_lifetime_ms() + 5_000
  end

  defp sse_receive_loop(conn, image_id, user, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    timeout = min(max(remaining, 0), 15_000)

    receive do
      {:upload_complete, %{status: status} = msg} ->
        Phoenix.PubSub.unsubscribe(Core.PubSub, "upload:#{image_id}")
        book_ids = Map.get(msg, :book_ids, [])
        book_id = List.first(book_ids)
        rejection_reason = Map.get(msg, :rejection_reason)
        is_duplicate = Enum.any?(book_ids, &Shelving.book_on_any_shelf?(user.id, &1))

        payload =
          ProtoJSON.poll_response(%{
            image_id: image_id,
            status: status,
            book_id: book_id,
            book_ids: book_ids,
            rejection_reason: rejection_reason,
            is_duplicate: is_duplicate
          })

        {:ok, conn} = chunk(conn, "data: #{Jason.encode!(payload)}\n\n")
        conn

      :heartbeat ->
        {:ok, conn} = chunk(conn, "data: {\"type\":\"heartbeat\"}\n\n")
        sse_receive_loop(conn, image_id, user, deadline)
    after
      timeout ->
        if remaining <= 0 do
          Phoenix.PubSub.unsubscribe(Core.PubSub, "upload:#{image_id}")

          :telemetry.execute(
            [:stacks, :upload, :terminal],
            %{count: 1},
            %{outcome: :timeout}
          )

          timeout_payload =
            ProtoJSON.poll_response(%{
              image_id: image_id,
              status: "timeout",
              book_id: nil,
              book_ids: [],
              rejection_reason: nil,
              is_duplicate: false
            })

          {:ok, conn} = chunk(conn, "data: " <> Jason.encode!(timeout_payload) <> "\n\n")
          conn
        else
          {:ok, conn} = chunk(conn, "data: {\"type\":\"heartbeat\"}\n\n")
          sse_receive_loop(conn, image_id, user, deadline)
        end
    end
  end

  defp effective_book_ids([_ | _] = ids, _), do: ids
  defp effective_book_ids([], nil), do: []
  defp effective_book_ids([], book_id), do: [book_id]

  defp decode_uuid(nil), do: nil
  defp decode_uuid(<<_::128>> = bin), do: elem(Ecto.UUID.load(bin), 1)
  defp decode_uuid(str) when is_binary(str) and byte_size(str) == 36, do: str
  defp decode_uuid(_), do: nil

  defp decode_uuid_list(nil), do: []
  defp decode_uuid_list(bins), do: Enum.map(bins, &decode_uuid/1) |> Enum.reject(&is_nil/1)
end
