defmodule Stacks.Partners do
  @moduledoc """
  Context for partner registration, approval, and API key management.
  Partners are third-space businesses (bookshops, cafes, reading groups).
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Core.Repo
  alias Stacks.Partners.Partner

  @key_prefix "sk_partner_"
  @key_hex_length 40

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
  Returns {:ok, {Partner, raw_key}} or {:error, :not_found | :already_approved}.
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
  Returns {:ok, raw_key} or {:error, :not_found | :not_approved}.
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
  with Argon2. Returns {:ok, Partner} or {:error, :invalid}.
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
end
