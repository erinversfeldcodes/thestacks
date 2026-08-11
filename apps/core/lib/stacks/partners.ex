defmodule Stacks.Partners do
  @moduledoc """
    Context for partner registration, approval, API key management,
    inventory sync, and event management.
    Partners are third-space businesses (bookshops, cafes, reading groups).
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Core.Repo
  alias Stacks.Books.BookEdition
  alias Stacks.Enrichment.ThirdSpaceEvent
  alias Stacks.Events
  alias Stacks.Partners.{InventoryItem, Partner}

  @key_prefix "stacks_pk_"
  @key_hex_length 64

  @partner_required_fields [:name, :business_type, :contact_email]
  @partner_optional_fields [:website_url]
  @valid_business_types ~w(bookshop cafe reading_group other)

  def partner_changeset(partner, attrs) do
    partner
    |> cast(attrs, @partner_required_fields ++ @partner_optional_fields)
    |> validate_required(@partner_required_fields)
    |> validate_inclusion(:business_type, @valid_business_types)
    |> validate_format(:contact_email, ~r/@/)
    |> unique_constraint(:contact_email)
    |> put_default(:status, "pending")
  end

  defp put_default(changeset, field, value) do
    if get_field(changeset, field), do: changeset, else: put_change(changeset, field, value)
  end

  @doc "Register a new partner. Returns {:ok, Partner} or {:error, changeset}."
  def register_partner(attrs) do
    %Partner{}
    |> partner_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
    Approve a partner registration. Generates an HMAC secret, stores its Argon2 hash,
    and returns the raw key ONCE. The key is never recoverable after this call.
    Returns {:ok, {Partner, raw_key}} or {:error,:not_found |:already_approved}.
  """
  def approve_partner(partner_id, admin_id) do
    case Repo.get(Partner, partner_id) do
      nil ->
        {:error, :not_found}

      %Partner{status: "approved"} ->
        {:error, :already_approved}

      partner ->
        raw_key = generate_key()
        hashed = Argon2.hash_pwd_salt(raw_key)
        prefix = String.slice(raw_key, 0, 8)

        result =
          partner
          |> change(%{
            status: "approved",
            hmac_secret: hashed,
            api_key_prefix: prefix,
            approved_by_id: admin_id,
            approved_at: DateTime.utc_now()
          })
          |> Repo.update()

        case result do
          {:ok, updated} -> {:ok, {updated, raw_key}}
          {:error, cs} -> {:error, cs}
        end
    end
  end

  @doc "Reject a partner registration."
  def reject_partner(partner_id, admin_id, _reason \\ nil) do
    case Repo.get(Partner, partner_id) do
      nil ->
        {:error, :not_found}

      partner ->
        partner
        |> change(%{
          status: "rejected",
          approved_by_id: admin_id,
          approved_at: DateTime.utc_now()
        })
        |> Repo.update()
    end
  end

  @doc """
    Rotate the API key for an approved partner.
    Returns {:ok, raw_key} or {:error,:not_found |:not_approved}.
  """
  def rotate_key(partner_id) do
    case Repo.get(Partner, partner_id) do
      nil ->
        {:error, :not_found}

      %Partner{status: status} when status != "approved" ->
        {:error, :not_approved}

      partner ->
        raw_key = generate_key()
        hashed = Argon2.hash_pwd_salt(raw_key)
        prefix = String.slice(raw_key, 0, 8)

        case partner |> change(%{hmac_secret: hashed, api_key_prefix: prefix}) |> Repo.update() do
          {:ok, _} -> {:ok, raw_key}
          {:error, cs} -> {:error, cs}
        end
    end
  end

  @doc """
    Authenticate a partner by raw API key. Scans approved partners and verifies
    with Argon2. Returns {:ok, Partner} or {:error,:invalid}.
    NOTE: This is O(n) over approved partners. In production, add a prefix index.
  """
  def authenticate_partner(raw_key) do
    prefix = String.slice(raw_key, 0, 8)

    partner =
      Repo.one(
        from p in Partner,
          where: p.status == "approved" and p.api_key_prefix == ^prefix
      )

    case partner do
      nil ->
        Argon2.no_user_verify()
        {:error, :invalid}

      %Partner{hmac_secret: hash} ->
        if Argon2.verify_pass(raw_key, hash) do
          {:ok, partner}
        else
          {:error, :invalid}
        end
    end
  end

  @doc "List all partners with status = 'pending'."
  def list_pending_partners do
    Repo.all(from p in Partner, where: p.status == "pending", order_by: [asc: p.created_at])
  end

  defp generate_key do
    hex = :crypto.strong_rand_bytes(div(@key_hex_length, 2)) |> Base.encode16(case: :lower)
    @key_prefix <> hex
  end

  @valid_conditions ~w(new like_new good fair poor)

  @doc """
    Changeset for a partner inventory item.
  """
  @spec inventory_item_changeset(InventoryItem.t(), map()) :: Ecto.Changeset.t()
  def inventory_item_changeset(item, attrs) do
    item
    |> cast(attrs, [
      :partner_id,
      :book_edition_id,
      :price_cents,
      :condition,
      :quantity,
      :synced_at
    ])
    |> validate_required([:partner_id, :book_edition_id, :price_cents, :condition])
    |> validate_number(:price_cents, greater_than: 0)
    |> validate_inclusion(:condition, @valid_conditions)
    |> validate_number(:quantity, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:partner_id)
    |> foreign_key_constraint(:book_edition_id)
    |> unique_constraint([:partner_id, :book_edition_id],
      name: "partner_inventory_partner_edition_uniq"
    )
  end

  @doc """
    Sync a list of inventory items for a partner. Each item has isbn, price_cents,
    condition, and quantity. Returns `{synced_count, unresolved_isbns}`.
  """
  @spec sync_inventory(Partner.t(), [map()]) ::
          {:ok, %{synced: integer(), unresolved: [String.t()]}}
  def sync_inventory(%Partner{id: partner_id}, items) when is_list(items) do
    now = DateTime.utc_now()

    {synced, unresolved} =
      Enum.reduce(items, {0, []}, fn item, {s, u} ->
        sync_single_item(item, partner_id, now, {s, u})
      end)

    result = %{synced: synced, unresolved: Enum.reverse(unresolved)}

    Events.emit_safe(%{
      event_type: "partner.inventory_synced",
      aggregate_type: "partner",
      aggregate_id: partner_id,
      payload: %{synced: synced, unresolved_count: length(result.unresolved)}
    })

    {:ok, result}
  end

  defp sync_single_item(item, partner_id, now, {s, u}) do
    isbn = item |> Map.get("isbn", "") |> String.replace("-", "")

    case resolve_edition_by_isbn(isbn) do
      nil ->
        {s, [isbn | u]}

      edition_id ->
        attrs = %{
          partner_id: partner_id,
          book_edition_id: edition_id,
          price_cents: item["price_cents"],
          condition: item["condition"],
          quantity: Map.get(item, "quantity", 1),
          synced_at: now
        }

        case upsert_inventory_item(attrs) do
          {:ok, _} -> {s + 1, u}
          {:error, _} -> {s, [isbn | u]}
        end
    end
  end

  @doc """
    List inventory items for a partner.
  """
  @spec list_inventory(Partner.t()) :: [InventoryItem.t()]
  def list_inventory(%Partner{id: partner_id}) do
    InventoryItem
    |> where([i], i.partner_id == ^partner_id)
    |> order_by([i], desc: i.synced_at)
    |> Repo.all()
    |> Repo.preload(:book_edition)
  end

  defp resolve_edition_by_isbn(isbn) when byte_size(isbn) > 0 do
    Repo.one(from e in BookEdition, where: e.isbn == ^isbn, select: e.id, limit: 1)
  end

  defp resolve_edition_by_isbn(_), do: nil

  defp upsert_inventory_item(attrs) do
    %InventoryItem{}
    |> inventory_item_changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:price_cents, :condition, :quantity, :synced_at, :updated_at]},
      conflict_target: [:partner_id, :book_edition_id],
      returning: true
    )
  end

  @doc """
    Create a third space event for a partner's linked third space.
    Returns {:error,:no_third_space} if the partner has no linked space.
    Validates that starts_at is in the future and ends_at > starts_at.
  """
  @spec create_partner_event(Partner.t(), map()) ::
          {:ok, ThirdSpaceEvent.t()} | {:error, atom() | Ecto.Changeset.t()}
  def create_partner_event(%Partner{third_space_id: nil}, _attrs) do
    {:error, :no_third_space}
  end

  def create_partner_event(%Partner{third_space_id: space_id}, attrs) do
    with {:ok, starts_at} <- parse_datetime(attrs["starts_at"]),
         {:ok, ends_at} <- parse_datetime(attrs["ends_at"]),
         :ok <- validate_future(starts_at),
         :ok <- validate_ends_after_starts(starts_at, ends_at) do
      event_attrs = %{
        space_id: space_id,
        title: attrs["title"],
        description: attrs["description"],
        event_date: starts_at,
        ends_at: ends_at,
        source_url: attrs["location"],
        scraped_at: DateTime.utc_now()
      }

      case %ThirdSpaceEvent{}
           |> Stacks.Enrichment.third_space_event_changeset(event_attrs)
           |> Repo.insert() do
        {:ok, event} = result ->
          Events.emit_safe(%{
            event_type: "partner.event_created",
            aggregate_type: "third_space_event",
            aggregate_id: event.id,
            payload: %{space_id: space_id, title: event.title}
          })

          result

        error ->
          error
      end
    end
  end

  @doc """
    List events for a partner's linked third space.
  """
  @spec list_partner_events(Partner.t()) :: [ThirdSpaceEvent.t()]
  def list_partner_events(%Partner{third_space_id: nil}), do: []

  def list_partner_events(%Partner{third_space_id: space_id}) do
    ThirdSpaceEvent
    |> where([e], e.space_id == ^space_id)
    |> order_by([e], asc: e.event_date)
    |> Repo.all()
  end

  @doc """
    Delete an event belonging to a partner's third space.
    Returns {:error,:not_found} if the event doesn't exist or belongs to another space.
  """
  @spec delete_partner_event(Partner.t(), String.t()) ::
          {:ok, ThirdSpaceEvent.t()} | {:error, :not_found | :no_third_space}
  def delete_partner_event(%Partner{third_space_id: nil}, _event_id) do
    {:error, :no_third_space}
  end

  def delete_partner_event(%Partner{third_space_id: space_id}, event_id) do
    case Repo.one(
           from e in ThirdSpaceEvent,
             where: e.id == ^event_id and e.space_id == ^space_id
         ) do
      nil ->
        {:error, :not_found}

      event ->
        case Repo.delete(event) do
          {:ok, _} = result ->
            Events.emit_safe(%{
              event_type: "partner.event_deleted",
              aggregate_type: "third_space_event",
              aggregate_id: event_id,
              payload: %{space_id: space_id}
            })

            result

          error ->
            error
        end
    end
  end

  defp parse_datetime(nil), do: {:error, :invalid_datetime}

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_), do: {:error, :invalid_datetime}

  defp validate_future(dt) do
    if DateTime.compare(dt, DateTime.utc_now()) == :gt do
      :ok
    else
      {:error, :starts_in_past}
    end
  end

  defp validate_ends_after_starts(starts_at, ends_at) do
    if DateTime.compare(ends_at, starts_at) == :gt do
      :ok
    else
      {:error, :ends_before_starts}
    end
  end
end
