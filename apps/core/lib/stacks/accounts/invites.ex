defmodule Stacks.Accounts.Invites do
  @moduledoc """
      Closed-beta invitations. The code is a bearer secret:
      128 random bits in Crockford base32, shown ONCE; only its SHA-256
      (`code_hash`, the redemption lookup) and a display prefix survive.
      SHA-256 not Argon2 because the row must be FOUND by code — and the code
      is high-entropy and never reused, so a fast hash is right.

      Redemption runs INSIDE the registration `Ecto.Multi` (`redeem_steps/3`),
      never a plug, with `SELECT … FOR UPDATE` making single-use real under
      concurrency. `note`/`invited_email` are personal data about a possible
      never-user: scrubbed by `GDPR.Deletion`, excluded from export.
  """

  import Ecto.Query

  alias Core.Repo
  alias Ecto.Multi
  alias Stacks.Accounts.InviteCode
  alias Stacks.Audit
  alias Stacks.Events

  @code_bytes 16
  @crockford ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  @note_max_length 500

  @doc """
      Writes an invitation. Returns `{:ok, %{invite: row, code: full_code}}` —
      the ONLY place the full code ever exists in the clear.
  """
  @spec issue(Stacks.Accounts.User.t(), map()) ::
          {:ok, %{invite: InviteCode.t(), code: String.t()}} | {:error, Ecto.Changeset.t()}
  def issue(owner, attrs \\ %{}) do
    {code, hash, prefix} = generate_code()

    changeset =
      changeset(%InviteCode{}, %{
        "code_hash" => hash,
        "code_prefix" => prefix,
        "issued_by_id" => owner.id,
        "note" => attrs["note"],
        "invited_email" => attrs["invited_email"],
        "max_uses" => attrs["max_uses"] || 1,
        "expires_at" => expires_at_from(attrs)
      })

    with {:ok, invite} <- Repo.insert(changeset) do
      Events.emit_safe(%{
        event_type: "invite.issued",
        aggregate_type: "invite",
        aggregate_id: invite.id,
        payload: %{
          max_uses: invite.max_uses,
          expires_at: invite.expires_at && DateTime.to_iso8601(invite.expires_at),
          email_bound: not is_nil(invite.invited_email)
        }
      })

      Audit.log(owner.id, "invite.issued", resource_type: "invite", resource_id: invite.id)

      {:ok, %{invite: invite, code: code}}
    end
  end

  @doc "Every invitation, newest first, with the first redeemer's handle."
  @spec list() :: [map()]
  def list do
    from(i in InviteCode,
      left_join: u in assoc(i, :redeemed_by),
      order_by: [desc: i.created_at],
      select: {i, u.handle}
    )
    |> Repo.all()
    |> Enum.map(fn {invite, handle} -> %{invite: invite, redeemed_by_handle: handle} end)
  end

  @doc "Revokes an invitation — a timestamp, never a row delete."
  @spec revoke(Stacks.Accounts.User.t(), String.t()) ::
          {:ok, InviteCode.t()} | {:error, :not_found}
  def revoke(owner, id) do
    case Repo.get(InviteCode, id) do
      nil ->
        {:error, :not_found}

      invite ->
        invite = invite |> Ecto.Changeset.change(revoked_at: now()) |> Repo.update!()

        Events.emit_safe(%{
          event_type: "invite.revoked",
          aggregate_type: "invite",
          aggregate_id: invite.id,
          payload: %{}
        })

        Audit.log(owner.id, "invite.revoked", resource_type: "invite", resource_id: invite.id)

        {:ok, invite}
    end
  end

  @doc """
      What `POST /api/auth/invite/check` answers. Deliberately reveals nothing about
      a person: no note, no address (only whether one is bound), no redeemer.
  """
  @spec check(String.t()) ::
          {:ok, %{expires_at: DateTime.t() | nil, email_bound: boolean()}}
          | {:error, :invite_not_found | :invite_expired | :invite_revoked | :invite_exhausted}
  def check(code) do
    case Repo.get_by(InviteCode, code_hash: hash(code)) do
      nil ->
        {:error, :invite_not_found}

      invite ->
        case status(invite) do
          :ok ->
            {:ok, %{expires_at: invite.expires_at, email_bound: not is_nil(invite.invited_email)}}

          error ->
            error
        end
    end
  end

  @doc "The failure mode of a row, `:ok` when redeemable. Pure over the row and now."
  @spec status(InviteCode.t()) ::
          :ok | {:error, :invite_revoked | :invite_expired | :invite_exhausted}
  def status(%InviteCode{} = invite) do
    cond do
      not is_nil(invite.revoked_at) ->
        {:error, :invite_revoked}

      not is_nil(invite.expires_at) and DateTime.compare(invite.expires_at, now()) == :lt ->
        {:error, :invite_expired}

      invite.use_count >= invite.max_uses ->
        {:error, :invite_exhausted}

      true ->
        :ok
    end
  end

  @doc """
      The metric label for an invite-gate refusal — a bounded name for a reason.

      ⚠️ It lives HERE, next to the atoms, rather than in the controller that
      emits the metric, and the placement is the point. Every atom below is
      declared and produced in this module (`lock_invite/2`,
      `check_email_binding/2`, `status/1`), so a reason added here shows a reader
      a mapping sitting one screen away that does not know about it. On a
      controller the drift was invisible except to a test, and the mapping had in
      fact already drifted once.

      ⚠️ The catch-all is load-bearing and is NOT the six atoms being optional.
      This is reached from an unauthenticated registration path, through
      `Accounts.do_register/3`, which ends in `{:error, _, reason, _} ->
      {:error, reason}` — a pass-through over EVERY step of the registration
      Multi, present or future, not just the invite steps. So the input set is
      any atom any step of that Multi returns. `Accounts.register/2`'s spec lists
      the six and is therefore narrower than its own body, and dialyzer will not
      flag a spec narrower than the success typing without `--overspecs`, so that
      spec is documentation rather than a guarantee.

      Without the catch-all an unexpected atom raises `FunctionClauseError` and
      registration answers 500 — both the worst place for one and a
      distinguishable response on an endpoint designed to tell a prober nothing.
      `:other` keeps the label bounded, which is what a Prometheus label must be,
      while still recording that a refusal happened: an unexpected atom appearing
      as `other` is a signal to come and add a clause.

      ⚠️ An earlier version of this argument named `:invite_not_found` as "one
      `with` clause away from reaching here". That was plausible, unchecked and
      false — it is produced only by `check/1` and consumed only by the invite
      controller, which answers 404. Recorded rather than quietly removed,
      because it is the kind of claim the next reader would re-derive.
  """
  @spec telemetry_label(atom()) :: atom()
  def telemetry_label(:invite_required), do: :required
  def telemetry_label(:invite_invalid), do: :invalid
  def telemetry_label(:invite_expired), do: :expired
  def telemetry_label(:invite_revoked), do: :revoked
  def telemetry_label(:invite_exhausted), do: :exhausted
  def telemetry_label(:invite_email_mismatch), do: :email_mismatch
  def telemetry_label(_unexpected), do: :other

  @doc """
      Prepends the invite gate to a registration `Ecto.Multi`:

        1. `:lock_invite` — `SELECT … FOR UPDATE` by hash; the lock is the
           single-use guarantee.
        2. `:validate_invite` — revoked/expired/exhausted/email binding.

      …and appends, after the `:user` insert:

        3. `:consume_invite` — `use_count + 1`; records the FIRST redeemer.

      Steps are added only when the flag is on; when off, the multi is returned
      untouched and any submitted code is ignored (the story's contract).
  """
  @spec redeem_steps(Multi.t(), String.t() | nil, String.t() | nil) :: Multi.t()
  def redeem_steps(multi, code, email) do
    if Stacks.FeatureFlags.invite_only_registration?() do
      gate_steps(multi, code, email)
    else
      multi
    end
  end

  defp gate_steps(multi, code, email) do
    multi
    |> Multi.run(:lock_invite, fn repo, _changes -> lock_invite(repo, code) end)
    |> Multi.run(:validate_invite, fn _repo, %{lock_invite: invite} ->
      validate_invite(invite, email)
    end)
  end

  defp validate_invite(invite, email) do
    with :ok <- status_as_registration_error(invite),
         :ok <- check_email_binding(invite, email) do
      {:ok, invite}
    end
  end

  @doc "Appends `:consume_invite` when the gate steps are present in `multi`."
  @spec consume_steps(Multi.t()) :: Multi.t()
  def consume_steps(multi) do
    if Enum.any?(Multi.to_list(multi), fn {name, _} -> name == :lock_invite end) do
      Multi.run(multi, :consume_invite, fn repo, %{validate_invite: invite, user: user} ->
        consume_invite(repo, invite, user)
      end)
    else
      multi
    end
  end

  defp consume_invite(repo, invite, user) do
    first_redemption? = is_nil(invite.redeemed_by_id)

    changes =
      [use_count: invite.use_count + 1] ++
        if first_redemption?,
          do: [redeemed_by_id: user.id, redeemed_at: now()],
          else: []

    invite = invite |> Ecto.Changeset.change(changes) |> repo.update!()

    Events.emit_safe(%{
      event_type: "invite.redeemed",
      aggregate_type: "invite",
      aggregate_id: invite.id,
      payload: %{user_id: user.id, use_count: invite.use_count}
    })

    {:ok, invite}
  end

  @doc "Generates `{full_code, sha256_hex, display_prefix}`."
  @spec generate_code() :: {String.t(), String.t(), String.t()}
  def generate_code do
    body =
      @code_bytes
      |> :crypto.strong_rand_bytes()
      |> crockford()
      |> Enum.chunk_every(4)
      |> Enum.map_join("-", &to_string/1)

    code = "STK-" <> body
    prefix = code |> String.split("-") |> Enum.take(3) |> Enum.join("-")
    {code, hash(code), prefix}
  end

  @doc "SHA-256 hex of the normalised code (case- and hyphen-insensitive)."
  @spec hash(String.t()) :: String.t()
  def hash(code) do
    :crypto.hash(:sha256, normalise(code)) |> Base.encode16(case: :lower)
  end

  defp normalise(code) do
    code |> String.upcase() |> String.replace(~r/[^0-9A-Z]/, "")
  end

  defp crockford(bytes) do
    for <<chunk::5 <- pad_to_5(bytes)>>, do: Enum.at(@crockford, chunk)
  end

  defp pad_to_5(bytes) do
    bits = bit_size(bytes)
    rem = rem(bits, 5)
    if rem == 0, do: bytes, else: <<bytes::bitstring, 0::size(5 - rem)>>
  end

  defp changeset(invite, attrs) do
    invite
    |> Ecto.Changeset.cast(attrs, [
      :code_hash,
      :code_prefix,
      :issued_by_id,
      :note,
      :invited_email,
      :max_uses,
      :expires_at
    ])
    |> Ecto.Changeset.validate_required([:code_hash, :code_prefix])
    |> Ecto.Changeset.validate_number(:max_uses, greater_than_or_equal_to: 1)
    |> Ecto.Changeset.validate_length(:note, max: @note_max_length)
    |> Ecto.Changeset.validate_format(:invited_email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must be a valid email address"
    )
    |> Ecto.Changeset.unique_constraint(:code_hash, name: "invite_codes_code_hash_index")
  end

  defp expires_at_from(%{"expires_at" => %DateTime{} = at}), do: at

  defp expires_at_from(attrs) do
    case Map.get(attrs, "expires_in_days", 30) do
      nil -> nil
      days -> DateTime.add(now(), days * 24 * 3600, :second)
    end
  end

  defp lock_invite(_repo, code) when code in [nil, ""], do: {:error, :invite_required}

  defp lock_invite(repo, code) do
    case repo.one(from(i in InviteCode, where: i.code_hash == ^hash(code), lock: "FOR UPDATE")) do
      nil -> {:error, :invite_invalid}
      invite -> {:ok, invite}
    end
  end

  defp status_as_registration_error(invite) do
    case status(invite) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_email_binding(%InviteCode{invited_email: nil}, _email), do: :ok

  defp check_email_binding(%InviteCode{invited_email: bound}, email)
       when is_binary(email) do
    if String.downcase(bound) == String.downcase(email) do
      :ok
    else
      {:error, :invite_email_mismatch}
    end
  end

  defp check_email_binding(_invite, _email), do: {:error, :invite_email_mismatch}

  defp now, do: DateTime.utc_now()
end
