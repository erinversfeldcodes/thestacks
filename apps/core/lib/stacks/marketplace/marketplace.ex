defmodule Stacks.Marketplace do
  @moduledoc """
    Context for marketplace features: listings, offer threads, offer messages,
    and transactions.

    Listing state machine:

        draft ──→ active ──→ removed
                    │
                    ├──→ expired
                    │
                    └──→ sold

    Valid transitions: draft→active, active→removed, active→expired, active→sold.
  """

  @dialyzer :no_opaque

  import Ecto.Changeset
  import Ecto.Query

  alias Core.Repo
  alias Ecto.Multi
  alias Stacks.Events
  alias Stacks.Marketplace.Listing
  alias Stacks.Shelving
  alias Stacks.Shelving.{Bookshelf, Placement}

  @valid_transitions %{
    "draft" => ~w(active),
    "active" => ~w(removed expired sold)
  }

  @default_limit 50

  @doc """
    Creates a new listing in `draft` status.

    Validates that the seller has an active (non-removed) placement of the book
    on one of their bookshelves. Returns `{:error,:no_placement}` if they don't.
  """
  @spec create_listing(binary(), map()) ::
          {:ok, Listing.t()} | {:error, :no_placement | Ecto.Changeset.t()}
  def create_listing(seller_id, attrs) do
    book_id = attrs[:book_id] || attrs["book_id"]

    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{"seller_id" => seller_id, "status" => "draft"})

    Multi.new()
    |> Multi.run(:placement, fn repo, _ ->
      case find_seller_placement_with_repo(repo, seller_id, book_id) do
        nil -> {:error, :no_placement}
        placement -> {:ok, placement}
      end
    end)
    |> Multi.insert(:listing, fn _ -> listing_changeset(%Listing{}, attrs) end)
    |> Multi.run(:emit_event, fn _repo, %{listing: listing} ->
      Events.emit_safe(%{
        event_type: "listing.created",
        aggregate_type: "listing",
        aggregate_id: listing.id,
        payload: %{book_id: listing.book_id, seller_id: seller_id}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{listing: listing}} -> {:ok, Repo.preload(listing, [:book, :seller])}
      {:error, :placement, :no_placement, _} -> {:error, :no_placement}
      {:error, :listing, changeset, _} -> {:error, changeset}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  defp unexpired(query) do
    now = DateTime.utc_now()

    where(query, [l], l.status == "active" and (is_nil(l.expires_at) or l.expires_at > ^now))
  end

  defp with_effective_status(nil), do: nil

  defp with_effective_status(%Listing{status: "active", expires_at: %DateTime{} = at} = listing) do
    if DateTime.compare(at, DateTime.utc_now()) == :gt do
      listing
    else
      %{listing | status: "expired"}
    end
  end

  defp with_effective_status(%Listing{} = listing), do: listing

  @doc "Fetches a single listing with book and seller preloaded."
  @spec get_listing(binary()) :: Listing.t() | nil
  def get_listing(id) do
    Listing
    |> Repo.get(id)
    |> Repo.preload([:book, :seller])
    |> with_effective_status()
  end

  @doc "Returns active listings, most recently listed first. Limited to `limit` (default 50)."
  @spec list_active_listings(keyword()) :: [Listing.t()]
  def list_active_listings(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    Listing
    |> unexpired()
    |> order_by([l], desc: l.listed_at)
    |> limit(^limit)
    |> preload([:book, :seller])
    |> Repo.all()
  end

  @doc """
    Builds discovery labels for the active listings of the given book ids.

    Returns a map `%{book_id => %{source: "listed", owner_handle: handle, price: formatted}}`
    for every book that has an active marketplace listing. An active listing is
    discoverable by design, so its seller's public handle and formatted
    price are surfaced as the search-hit provenance. When several active listings
    exist for one book, the most recently listed wins (deterministic). Books with
    no active listing are simply absent from the map.
  """
  @spec active_listing_labels([binary()]) :: %{binary() => map()}
  def active_listing_labels([]), do: %{}

  def active_listing_labels(book_ids) when is_list(book_ids) do
    Listing
    |> join(:inner, [l], s in assoc(l, :seller))
    |> unexpired()
    |> where([l], l.book_id in ^book_ids)
    |> order_by([l], desc: l.listed_at)
    |> select([l, s], {l.book_id, s.handle, l.price_cents, l.currency})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {book_id, handle, cents, currency}, acc ->
      Map.put_new(acc, book_id, %{
        source: "listed",
        owner_handle: handle || "",
        price: format_price(cents, currency)
      })
    end)
  end

  @doc """
    Formats a listing price for display. ZAR renders with the "R" symbol;
    any other currency falls back to its code prefix. Whole-rand amounts omit the
    decimals ("R120"); fractional amounts keep two ("R120.50").
  """
  @spec format_price(integer(), String.t()) :: String.t()
  def format_price(cents, currency) when is_integer(cents) do
    symbol = if currency == "ZAR", do: "R", else: "#{currency} "
    rands = div(cents, 100)
    remainder = rem(cents, 100)

    if remainder == 0 do
      "#{symbol}#{rands}"
    else
      "#{symbol}#{rands}.#{String.pad_leading(Integer.to_string(remainder), 2, "0")}"
    end
  end

  @doc "Returns listings for a given seller, newest first. Limited to `limit` (default 50)."
  @spec list_user_listings(binary(), keyword()) :: [Listing.t()]
  def list_user_listings(seller_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    Listing
    |> where([l], l.seller_id == ^seller_id)
    |> order_by([l], desc: l.created_at)
    |> limit(^limit)
    |> preload([:book, :seller])
    |> Repo.all()
    |> Enum.map(&with_effective_status/1)
  end

  @doc """
    Activates a draft listing: draft → active.

    Sets `listed_at` to now, sets `expires_at` to 30 days from now,
    and denormalizes `listing_status = "active"` on the seller's placement.
  """
  @spec activate_listing(Listing.t(), binary()) ::
          {:ok, Listing.t()} | {:error, :unauthorized | :invalid_transition | Ecto.Changeset.t()}
  def activate_listing(%Listing{} = listing, user_id) do
    with :ok <- verify_ownership(listing, user_id) do
      now = DateTime.utc_now()
      expires_at = DateTime.add(now, 30, :day)

      Multi.new()
      |> Multi.run(:locked_listing, fn repo, _ ->
        lock_and_validate_transition(repo, listing.id, "active")
      end)
      |> Multi.update(:listing, fn %{locked_listing: locked} ->
        listing_changeset(locked, %{
          status: "active",
          listed_at: now,
          expires_at: expires_at
        })
      end)
      |> Multi.run(:denormalize, fn repo, %{listing: l} ->
        update_placement_listing_status(repo, user_id, l.book_id, "active")
      end)
      |> Multi.run(:emit_event, fn _repo, %{listing: l} ->
        Events.emit_safe(%{
          event_type: "listing.activated",
          aggregate_type: "listing",
          aggregate_id: l.id,
          payload: %{book_id: l.book_id, seller_id: user_id}
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{listing: listing}} -> {:ok, Repo.preload(listing, [:book, :seller])}
        {:error, :locked_listing, reason, _} -> {:error, reason}
        {:error, :listing, changeset, _} -> {:error, changeset}
        {:error, _, reason, _} -> {:error, reason}
      end
    end
  end

  @doc """
    Deactivates an active listing: active → removed.

    Clears `listing_status` on the seller's placement.
  """
  @spec deactivate_listing(Listing.t(), binary()) ::
          {:ok, Listing.t()} | {:error, :unauthorized | :invalid_transition | Ecto.Changeset.t()}
  def deactivate_listing(%Listing{} = listing, user_id) do
    with :ok <- verify_ownership(listing, user_id) do
      Multi.new()
      |> Multi.run(:locked_listing, fn repo, _ ->
        lock_and_validate_transition(repo, listing.id, "removed")
      end)
      |> Multi.update(:listing, fn %{locked_listing: locked} ->
        listing_changeset(locked, %{status: "removed"})
      end)
      |> Multi.run(:denormalize, fn repo, %{listing: l} ->
        update_placement_listing_status(repo, user_id, l.book_id, nil)
      end)
      |> Multi.run(:emit_event, fn _repo, %{listing: l} ->
        Events.emit_safe(%{
          event_type: "listing.removed",
          aggregate_type: "listing",
          aggregate_id: l.id,
          payload: %{book_id: l.book_id, seller_id: user_id}
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{listing: listing}} -> {:ok, Repo.preload(listing, [:book, :seller])}
        {:error, :locked_listing, reason, _} -> {:error, reason}
        {:error, :listing, changeset, _} -> {:error, changeset}
        {:error, _, reason, _} -> {:error, reason}
      end
    end
  end

  @doc """
    Marks an active listing as sold: active → sold.

    Sets `sold_at` to now and clears `listing_status` on the seller's placement.
  """
  @spec sold_listing(Listing.t(), binary()) ::
          {:ok, Listing.t()} | {:error, :unauthorized | :invalid_transition | Ecto.Changeset.t()}
  def sold_listing(%Listing{} = listing, user_id) do
    with :ok <- verify_ownership(listing, user_id) do
      now = DateTime.utc_now()

      Multi.new()
      |> Multi.run(:locked_listing, fn repo, _ ->
        lock_and_validate_transition(repo, listing.id, "sold")
      end)
      |> Multi.update(:listing, fn %{locked_listing: locked} ->
        listing_changeset(locked, %{status: "sold", sold_at: now})
      end)
      |> Multi.run(:denormalize, fn repo, %{listing: l} ->
        update_placement_listing_status(repo, user_id, l.book_id, nil)
      end)
      |> Multi.run(:emit_event, fn _repo, %{listing: l} ->
        Events.emit_safe(%{
          event_type: "listing.sold",
          aggregate_type: "listing",
          aggregate_id: l.id,
          payload: %{book_id: l.book_id, seller_id: user_id}
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{listing: listing}} -> {:ok, Repo.preload(listing, [:book, :seller])}
        {:error, :locked_listing, reason, _} -> {:error, reason}
        {:error, :listing, changeset, _} -> {:error, changeset}
        {:error, _, reason, _} -> {:error, reason}
      end
    end
  end

  @doc """
    Expires an active listing: active → expired.

    Called by ListingExpiryJob for listings past their `expires_at`.
    Clears `listing_status` on the seller's placement.
  """
  @spec expire_listing(Listing.t()) ::
          {:ok, Listing.t()} | {:error, :invalid_transition | Ecto.Changeset.t()}
  def expire_listing(%Listing{} = listing) do
    Multi.new()
    |> Multi.run(:locked_listing, fn repo, _ ->
      lock_and_validate_transition(repo, listing.id, "expired")
    end)
    |> Multi.update(:listing, fn %{locked_listing: locked} ->
      listing_changeset(locked, %{status: "expired"})
    end)
    |> Multi.run(:denormalize, fn repo, %{listing: l} ->
      update_placement_listing_status(repo, l.seller_id, l.book_id, nil)
    end)
    |> Multi.run(:emit_event, fn _repo, %{listing: l} ->
      Events.emit_safe(%{
        event_type: "listing.expired",
        aggregate_type: "listing",
        aggregate_id: l.id,
        payload: %{book_id: l.book_id, seller_id: l.seller_id}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{listing: listing}} -> {:ok, Repo.preload(listing, [:book, :seller])}
      {:error, :locked_listing, reason, _} -> {:error, reason}
      {:error, :listing, changeset, _} -> {:error, changeset}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  @listing_required_fields [:book_id, :seller_id, :pricing_mode, :price_cents, :condition]
  @listing_optional_fields [
    :status,
    :currency,
    :description,
    :contact_info,
    :photo_urls,
    :listed_at,
    :expires_at,
    :sold_at
  ]

  @listing_valid_statuses ~w(draft active sold removed expired)
  @listing_valid_pricing_modes ~w(fixed offer)
  @listing_valid_conditions ~w(new like_new good fair poor)

  @doc "Changeset for creating or updating a listing."
  def listing_changeset(listing, attrs) do
    listing
    |> cast(attrs, @listing_required_fields ++ @listing_optional_fields)
    |> validate_required(@listing_required_fields)
    |> validate_inclusion(:status, @listing_valid_statuses)
    |> validate_inclusion(:pricing_mode, @listing_valid_pricing_modes)
    |> validate_inclusion(:condition, @listing_valid_conditions)
    |> validate_number(:price_cents, greater_than: 0)
    |> validate_length(:contact_info, max: 500)
    |> unique_constraint([:book_id, :seller_id],
      name: "listings_active_book_seller_idx",
      message: "already has a draft or active listing for this book"
    )
  end

  @offer_thread_required_fields [:placement_id, :buyer_id]
  @offer_thread_optional_fields [:status]
  @offer_thread_valid_statuses ~w(open accepted declined expired)

  @doc "Changeset for creating or updating an offer thread."
  def offer_thread_changeset(thread, attrs) do
    thread
    |> cast(attrs, @offer_thread_required_fields ++ @offer_thread_optional_fields)
    |> validate_required(@offer_thread_required_fields)
    |> validate_inclusion(:status, @offer_thread_valid_statuses)
    |> unique_constraint([:placement_id, :buyer_id])
  end

  @offer_message_required_fields [:thread_id, :sender_id, :type]
  @offer_message_optional_fields [:body, :amount_cents]
  @offer_message_valid_types ~w(message offer counter accept decline)

  @doc "Changeset for creating an offer message."
  def offer_message_changeset(message, attrs) do
    message
    |> cast(attrs, @offer_message_required_fields ++ @offer_message_optional_fields)
    |> validate_required(@offer_message_required_fields)
    |> validate_inclusion(:type, @offer_message_valid_types)
  end

  @transaction_required_fields [:listing_id, :amount_cents, :payment_status]
  @transaction_optional_fields [
    :offer_id,
    :buyer_id,
    :seller_id,
    :currency,
    :payment_provider_ref,
    :shipping_provider_ref,
    :shipping_status,
    :shipping_cost_cents,
    :completed_at
  ]

  @transaction_valid_payment_statuses ~w(pending paid failed refunded)
  @transaction_valid_shipping_statuses ~w(pending shipped delivered returned)

  @doc "Changeset for creating or updating a transaction."
  def transaction_changeset(transaction, attrs) do
    transaction
    |> cast(attrs, @transaction_required_fields ++ @transaction_optional_fields)
    |> validate_required(@transaction_required_fields)
    |> validate_inclusion(:payment_status, @transaction_valid_payment_statuses)
    |> validate_inclusion(:shipping_status, @transaction_valid_shipping_statuses)
  end

  defp verify_ownership(%Listing{seller_id: seller_id}, user_id) do
    if seller_id == user_id, do: :ok, else: {:error, :unauthorized}
  end

  defp validate_transition(current_status, target_status) do
    allowed = Map.get(@valid_transitions, current_status, [])

    if target_status in allowed do
      :ok
    else
      {:error, :invalid_transition}
    end
  end

  defp lock_and_validate_transition(repo, listing_id, target_status) do
    case repo.one(from(l in Listing, where: l.id == ^listing_id, lock: "FOR UPDATE")) do
      nil ->
        {:error, :not_found}

      %Listing{} = locked ->
        case validate_transition(locked.status, target_status) do
          :ok -> {:ok, locked}
          error -> error
        end
    end
  end

  defp find_seller_placement_with_repo(repo, seller_id, book_id) when is_binary(book_id) do
    query =
      Placement
      |> join(:inner, [p], bs in Bookshelf,
        on: p.bookshelf_id == bs.id and bs.user_id == ^seller_id
      )
      |> where([p], p.book_id == ^book_id and is_nil(p.removed_at))
      |> limit(1)

    repo.one(query)
  end

  defp find_seller_placement_with_repo(_repo, _seller_id, _book_id), do: nil

  defp update_placement_listing_status(repo, user_id, book_id, status) do
    case find_seller_placement_with_repo(repo, user_id, book_id) do
      nil when status != nil ->
        {:error, :placement_not_found}

      nil ->
        {:ok, nil}

      placement ->
        placement
        |> Shelving.placement_changeset(%{listing_status: status})
        |> repo.update()
    end
  end
end
