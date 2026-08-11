defmodule Stacks.Accounts do
  @moduledoc """
    Accounts context — user registration, authentication, and retrieval.

    The first user registered on the platform automatically receives the `owner` role.
    Passwords are hashed with Argon2. Authentication returns a Guardian JWT token.
  """

  # Ecto.Multi uses an opaque MapSet internally; dialyzer cannot resolve the
  # opaque subterms after Multi.new() and fires call_without_opaque on every
  # chained call. This is a known false positive.
  @dialyzer :no_opaque

  require Logger

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Core.Repo
  alias Ecto.Multi
  alias Guardian.DB.Token, as: GuardianDbToken
  alias Stacks.Accounts.ArgonPool
  alias Stacks.Accounts.AuthTokenFamily
  alias Stacks.Accounts.Invites
  alias Stacks.Accounts.ReservedHandles
  alias Stacks.Accounts.User
  alias Stacks.Duration
  alias Stacks.Events
  alias Stacks.GDPR.Deletion
  alias Stacks.Social.UserBlock
  alias Stacks.Workers.VisibilityRecapJob

  @unverified_account_ttl_seconds 24 * 60 * 60

  @unverified_account_max_lifetime_seconds 7 * 24 * 60 * 60

  @registration_required_fields [:email, :password]
  @registration_optional_fields [:display_name, :role, :profile_visibility]

  @valid_onboarding_steps ~w(profile privacy)
  @onboarding_step_order ~w(profile privacy)

  @doc "The ordered list of onboarding steps — single source for callers/serializers."
  @spec onboarding_step_order() :: [String.t()]
  def onboarding_step_order, do: @onboarding_step_order

  @doc "Changeset for registration."
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, @registration_required_fields ++ @registration_optional_fields)
    |> validate_required(@registration_required_fields)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email address")
    |> downcase_email()
    |> validate_length(:password, min: 8, message: "must be at least 8 characters")
    |> validate_inclusion(:role, ["owner", "user"])
    |> validate_inclusion(:profile_visibility, Stacks.Visibility.profile_audience_levels())
    |> maybe_put_handle()
    |> validate_handle()
    |> unique_constraint(:email)
    |> unique_constraint(:email, name: :users_lower_email_index)
    |> hash_password()
  end

  @doc "Changeset for consent updates."
  def consent_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :consent_analytics,
      :consent_analytics_at,
      :consent_writing_assistant,
      :consent_writing_assistant_at
    ])
  end

  @doc """
    Changeset for provider-sourced age verification (ADR-020). Writes all three
    age-verification fields together — the ONLY path that may set `:age_verified`.
    Never fed by direct user input; called by `Stacks.AgeVerification`.
  """
  def verification_changeset(user, attrs) do
    user
    |> cast(attrs, [:age_verified, :age_verified_at, :age_verification_provider])
  end

  @doc "Changeset for profile update (display_name, website_url)."
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:display_name, :website_url, :handle, :syndication_default])
    |> drop_blank_handle_change()
    |> validate_length(:website_url, max: 500)
    |> validate_handle()
  end

  defp drop_blank_handle_change(changeset) do
    case fetch_change(changeset, :handle) do
      {:ok, nil} -> delete_change(changeset, :handle)
      _ -> changeset
    end
  end

  @doc "Changeset for email update. Requires current_password to be verified externally."
  def email_changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email address")
    |> downcase_email()
    |> unique_constraint(:email)
    |> unique_constraint(:email, name: :users_lower_email_index)
  end

  defp downcase_email(changeset) do
    case get_change(changeset, :email) do
      nil -> changeset
      email -> put_change(changeset, :email, normalise_email(email))
    end
  end

  @doc "Changeset for location update (country_code, city)."
  def location_changeset(user, attrs) do
    user
    |> cast(attrs, [:country_code, :city])
    |> validate_length(:country_code, is: 2)
    |> validate_length(:city, max: 200)
  end

  @doc "Changeset for password change (new_password). Caller must verify current password externally."
  def password_change_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, message: "must be at least 8 characters")
    |> hash_password()
  end

  @doc "Changeset for notification preferences."
  def notifications_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :notify_wishlist_availability,
      :notify_marketplace,
      :notify_group_invitations,
      :notify_event_matches
    ])
  end

  @doc "Changeset for profile visibility setting."
  def profile_visibility_changeset(user, attrs) do
    user
    |> cast(attrs, [:profile_visibility])
    |> validate_inclusion(:profile_visibility, Stacks.Visibility.profile_audience_levels())
  end

  @doc "Changeset for updating onboarding_steps JSONB map."
  def onboarding_steps_changeset(user, attrs) do
    user
    |> cast(attrs, [:onboarding_steps])
  end

  @doc "Changeset for email confirmation token storage."
  def email_confirmation_changeset(user, attrs) do
    user
    |> cast(attrs, [:email_confirmation_token, :email_confirmed])
  end

  @doc "Changeset for password reset token storage."
  def password_reset_changeset(user, attrs) do
    user
    |> cast(attrs, [:password_reset_token, :password_reset_sent_at])
  end

  @doc "Changeset for completing a password reset. Validates the new plaintext password before hashing."
  def password_update_changeset(user, attrs) do
    user
    |> cast(attrs, [:password, :password_reset_token, :password_reset_sent_at])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, message: "must be at least 8 characters")
    |> hash_password()
  end

  defp hash_password(%Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset) do
    changeset
    |> put_change(:password_hash, Argon2.hash_pwd_salt(password))
    |> delete_change(:password)
  end

  defp hash_password(changeset), do: changeset

  @handle_format ~r/^[a-z0-9_]{3,30}$/

  @doc """
    Validates/normalises the `:handle` field: force-lowercase, format
    (`[a-z0-9_]{3,30}`), not reserved, and case-insensitively unique. Shared by
    registration and the settings profile update.
  """
  def validate_handle(changeset) do
    changeset
    |> update_change(:handle, &normalise_handle/1)
    |> validate_format(:handle, @handle_format,
      message: "must be 3-30 characters: lowercase letters, numbers, underscores"
    )
    |> validate_reserved_handle()
    |> unique_constraint(:handle, name: :users_lower_handle_index)
  end

  defp normalise_handle(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalise_handle(value), do: value

  defp validate_reserved_handle(changeset) do
    case get_change(changeset, :handle) do
      handle when is_binary(handle) ->
        if ReservedHandles.reserved?(handle),
          do: add_error(changeset, :handle, "is reserved"),
          else: changeset

      _ ->
        changeset
    end
  end

  defp maybe_put_handle(changeset) do
    case get_field(changeset, :handle) do
      nil -> put_change(changeset, :handle, generate_handle(get_field(changeset, :display_name)))
      _ -> changeset
    end
  end

  @doc """
    Generates a likely-unique handle from a display name: a slug of the name
    (≤20 chars, non-alphanumerics collapsed to `_`, `reader` when empty) plus a
    6-char random suffix. The random suffix makes a collision astronomically
    unlikely; `unique_constraint(:handle)` is the backstop. Mirrors the SQL backfill
    in `20260714200500_backfill_and_constrain_user_handles`.
  """
  @spec generate_handle(String.t() | nil) :: String.t()
  def generate_handle(display_name) do
    slugify_handle_base(display_name) <> "_" <> handle_random_suffix()
  end

  defp slugify_handle_base(name) when is_binary(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")
      |> String.slice(0, 20)

    if slug == "", do: "reader", else: slug
  end

  defp slugify_handle_base(_), do: "reader"

  defp handle_random_suffix do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower) |> String.slice(0, 6)
  end

  @doc """
    Returns a user by ID, or nil if not found.
  """
  @spec get_user(binary()) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

  @doc """
    Returns a user by ID, raising if not found.
  """
  @spec get_user!(binary()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
    Returns a user by email address, or nil if not found.
  """
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) do
    Repo.get_by(User, email: String.downcase(email))
  end

  @doc """
    Returns ALL users whose email matches case-insensitively — the lookup used to
    resolve an email to `user_id`(s) for GDPR erasure. Unlike `get_user_by_email/1`
    (an exact, downcased match that a mixed-case stored email can slip past), this
    folds case on both sides so every candidate surfaces. Returns a list precisely
    because an email is NOT a guaranteed-unique key (only `user_id` is) — the
    operator disambiguates, and the erasure itself takes a `user_id`.
  """
  @spec find_users_by_email(String.t()) :: [User.t()]
  def find_users_by_email(email) when is_binary(email) do
    normalised = String.downcase(String.trim(email))
    Repo.all(from u in User, where: fragment("lower(?)", u.email) == ^normalised)
  end

  def find_users_by_email(_), do: []

  @doc """
    Returns a user by public handle (case-insensitive), or nil if not found.
    Keys the public profile at `/u/:handle`.
  """
  @spec get_user_by_handle(String.t()) :: User.t() | nil
  def get_user_by_handle(handle) when is_binary(handle) do
    normalised = String.downcase(String.trim(handle))
    Repo.one(from u in User, where: fragment("lower(?)", u.handle) == ^normalised, limit: 1)
  end

  def get_user_by_handle(_), do: nil

  @doc """
    Seconds an email-confirmation link (and the unverified account behind it) stays
    valid after the link was issued. The confirmation token's `max_age`, the resend
    path, and the expired-account reaper all key off this one value.
  """
  @spec unverified_account_ttl_seconds() :: pos_integer()
  def unverified_account_ttl_seconds, do: @unverified_account_ttl_seconds

  @doc """
    IDs of accounts whose email-confirmation LINK is dead — never confirmed
    and holding no token that still verifies. Feeds
    `ExpiredUnverifiedAccountsJob`.

    ⛔ The reaper's clock is the LINK's clock, not `created_at`: resend
    mints a fresh token, so age alone would erase accounts under still-live
    links. The SQL is only a prefilter; the decision is the same
    `Phoenix.Token.verify/4` the confirm click makes.
  """
  @spec expired_unverified_ids(DateTime.t()) :: [binary()]
  def expired_unverified_ids(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@unverified_account_ttl_seconds, :second)

    candidates =
      Repo.all(
        from u in User,
          where: u.email_confirmed == false and u.created_at < ^cutoff,
          select: {u.id, u.email_confirmation_token}
      )

    for {id, token} <- candidates, not confirmation_link_live?(token), do: id
  end

  @doc """
    Verify a confirmation token and return the user id it was signed over.

    The ONE place the `"email_confirm"` salt and its `max_age` are spoken. Both
    readers of a confirmation link go through here — `Stacks.Email.confirm_email/1`
    when the reader clicks it, and `confirmation_link_live?/1` when the reaper asks
    whether that click would still work — so the two cannot drift into disagreeing
    about which links are alive.
  """
  @spec verify_confirmation_token(String.t() | nil) :: {:ok, binary()} | :error
  def verify_confirmation_token(token) when is_binary(token) do
    case Phoenix.Token.verify(CoreWeb.Endpoint, "email_confirm", token,
           max_age: @unverified_account_ttl_seconds
         ) do
      {:ok, user_id} -> {:ok, user_id}
      {:error, _reason} -> :error
    end
  end

  def verify_confirmation_token(_token), do: :error

  @doc """
    Sign a fresh confirmation link for `user_id`, valid for
    `unverified_account_ttl_seconds/0` from now. Issuing a link is also what keeps
    the account alive — see `expired_unverified_ids/1`.
  """
  @spec sign_confirmation_token(binary()) :: String.t()
  def sign_confirmation_token(user_id) do
    Phoenix.Token.sign(CoreWeb.Endpoint, "email_confirm", user_id)
  end

  @doc """
    The ceiling on an unconfirmed account's life, however often a link is resent.
    See `@unverified_account_max_lifetime_seconds`.
  """
  @spec unverified_account_max_lifetime_seconds() :: pos_integer()
  def unverified_account_max_lifetime_seconds, do: @unverified_account_max_lifetime_seconds

  @doc """
    Whether a fresh confirmation link may still be issued for `user`.

    False once the account has passed `unverified_account_max_lifetime_seconds/0`,
    which is what stops an anonymous caller renewing a stranger's signup forever.
    A refusal is invisible from outside — the endpoint's response does not depend
    on it — so this cannot become an account-age oracle.
  """
  @spec confirmation_resendable?(User.t()) :: boolean()
  def confirmation_resendable?(user), do: confirmation_resendable?(user, DateTime.utc_now())

  @spec confirmation_resendable?(User.t(), DateTime.t()) :: boolean()
  def confirmation_resendable?(%User{created_at: created_at}, now) do
    DateTime.diff(now, created_at) < @unverified_account_max_lifetime_seconds
  end

  @doc """
    Whether a stored `email_confirmation_token` would still be accepted if the
    reader clicked it right now. The single predicate behind "may the reaper erase
    the account behind this link".
  """
  @spec confirmation_link_live?(String.t() | nil) :: boolean()
  def confirmation_link_live?(token) do
    match?({:ok, _user_id}, verify_confirmation_token(token))
  end

  @doc """
    People search for discovery: up to 20 users matching `term` on
    `display_name` (ILIKE), restricted to discoverable profiles
    (`profile_visibility = "platform"`) and excluding blocks in either direction.
    The privacy rule is enforced IN SQL, never by serializer redaction — a row
    that shouldn't be seen is never selected.
  """
  @search_limit 20
  @spec search_users(String.t(), binary() | nil) :: [User.t()]
  def search_users(term, viewer_id \\ nil)

  def search_users(term, viewer_id) when is_binary(term) do
    trimmed = String.trim(term)

    if trimmed == "" do
      []
    else
      pattern = "%#{escape_like(String.downcase(trimmed))}%"

      discoverable =
        if is_nil(viewer_id), do: ["public"], else: ["platform", "public"]

      query =
        from(u in User,
          as: :candidate,
          where: u.profile_visibility in ^discoverable,
          where: ilike(fragment("lower(?)", u.display_name), ^pattern),
          order_by: [asc: u.display_name],
          limit: ^@search_limit
        )

      query
      |> exclude_blocked(viewer_id)
      |> Repo.all()
    end
  end

  def search_users(_term, _viewer_id), do: []

  defp exclude_blocked(query, nil), do: query

  defp exclude_blocked(query, viewer_id) do
    from(u in query,
      where:
        not exists(
          from(b in UserBlock,
            where:
              (b.blocker_id == ^viewer_id and b.blocked_id == parent_as(:candidate).id) or
                (b.blocker_id == parent_as(:candidate).id and b.blocked_id == ^viewer_id)
          )
        )
    )
  end

  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc """
    Marks a user's email as confirmed, clearing any pending confirmation token.

    Used by the token-based confirmation flow (`Stacks.Email.confirm_email/1`)
    and by trusted programmatic flows that bypass email verification
    (`Stacks.Release.seed_prod/0`). Any future confirmation side effects
    (audit, events, token cleanup across related channels) should be added
    here so every caller picks them up automatically.
  """
  @spec mark_confirmed(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def mark_confirmed(%User{} = user) do
    user
    |> email_confirmation_changeset(%{
      email_confirmed: true,
      email_confirmation_token: nil
    })
    |> Repo.update()
  end

  @doc """
    Registers a new user; the platform's first user becomes `owner`. Created
    unconfirmed with a confirmation token — the email is sent event-driven via
    `EmailConfirmationHandler`, and the user cannot authenticate until confirmed.
    `opts` may carry consent attrs recorded atomically with the insert.
  """
  @spec register(map(), keyword()) ::
          {:ok, User.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error,
             :invite_required
             | :invite_invalid
             | :invite_expired
             | :invite_revoked
             | :invite_exhausted
             | :invite_email_mismatch}
  def register(attrs, opts \\ []) do
    reap_abandoned_signups(attrs)

    attrs = maybe_assign_owner_role(attrs)
    do_register(attrs, 2, opts)
  end

  @reap_batch 5

  defp reap_abandoned_signups(attrs) do
    email = attrs[:email] || attrs["email"]

    ids =
      (abandoned_id_for_email(email) ++ expired_unverified_ids())
      |> Enum.uniq()
      |> Enum.take(@reap_batch)

    Enum.each(ids, fn id ->
      Deletion.delete_user_data(id,
        reason: "unverified account expired — email never confirmed within TTL",
        actor: "system:registration_reap",
        restore_invite: true
      )
    end)
  rescue
    error ->
      Logger.warning("Accounts.register: could not reap abandoned signups: #{inspect(error)}")
      :ok
  end

  defp abandoned_id_for_email(nil), do: []

  defp abandoned_id_for_email(email) do
    normalised = email |> to_string() |> String.downcase() |> String.trim()

    Repo.all(
      from u in User,
        where: fragment("lower(?)", u.email) == ^normalised and u.email_confirmed == false,
        select: u.id
    )
  end

  defp do_register(attrs, retries_left, opts) do
    Multi.new()
    |> then(fn multi ->
      if Keyword.get(opts, :skip_invite_gate, false) do
        multi
      else
        Invites.redeem_steps(
          multi,
          attrs[:invite_code] || attrs["invite_code"],
          attrs[:email] || attrs["email"]
        )
      end
    end)
    |> Multi.insert(:user, registration_changeset(%User{}, attrs))
    |> Multi.run(:set_confirmation, fn _repo, %{user: user} ->
      token = sign_confirmation_token(user.id)

      user
      |> email_confirmation_changeset(%{
        email_confirmed: false,
        email_confirmation_token: token
      })
      |> Repo.update()
    end)
    |> Multi.run(:emit_event, fn _repo, %{set_confirmation: user} ->
      Events.emit_safe(%{
        event_type: "user.registered",
        aggregate_type: "user",
        aggregate_id: user.id,
        payload: %{role: user.role}
      })

      {:ok, user}
    end)
    |> Invites.consume_steps()
    |> Repo.transaction()
    |> case do
      {:ok, %{set_confirmation: user}} ->
        {:ok, user}

      {:error, :user, changeset, _} ->
        if retries_left > 0 and handle_collision?(changeset) do
          do_register(attrs, retries_left - 1, opts)
        else
          {:error, changeset}
        end

      {:error, _, reason, _} ->
        {:error, reason}
    end
  end

  defp handle_collision?(changeset) do
    Enum.any?(changeset.errors, fn
      {:handle, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  @doc """
    Authenticates by email and password. `{:ok, user}` or `{:error, reason}`
    where reason is `:invalid_credentials`, `:email_unconfirmed`,
    `{:account_locked, retry_after_seconds}`, or `:argon2_busy`. Runs a dummy
    Argon2 verify on unknown emails so timing does not reveal existence, and
    counts failures toward per-account lockout.
  """
  @spec authenticate(String.t(), String.t()) ::
          {:ok, User.t()}
          | {:error,
             :invalid_credentials
             | :email_unconfirmed
             | :argon2_busy
             | {:account_locked, pos_integer()}}
  def authenticate(email, password) do
    with {:ok, user} <- check_password(get_user_by_email(email), password),
         :ok <- check_email_confirmed(user) do
      {:ok, user}
    end
  end

  defp check_password(nil, _password) do
    _ = ArgonPool.run(fn -> Argon2.no_user_verify() end)
    {:error, :invalid_credentials}
  end

  defp check_password(user, password) do
    now = DateTime.utc_now()

    case lockout_status(user, now) do
      {:locked, retry_after_seconds} ->
        {:error, {:account_locked, retry_after_seconds}}

      :unlocked ->
        verify_and_record(user, password, now)
    end
  end

  defp verify_and_record(user, password, now) do
    case ArgonPool.run(fn -> Argon2.verify_pass(password, user.password_hash) end) do
      true ->
        {:ok, clear_failed_logins(user, now)}

      false ->
        _ = record_failed_login(user, now)
        {:error, :invalid_credentials}

      {:error, :argon2_busy} ->
        {:error, :argon2_busy}
    end
  end

  @spec lockout_status(User.t(), DateTime.t()) :: :unlocked | {:locked, pos_integer()}
  defp lockout_status(%User{locked_until: nil}, _now), do: :unlocked

  defp lockout_status(%User{locked_until: locked_until}, now) do
    case DateTime.compare(locked_until, now) do
      :gt ->
        seconds = max(1, DateTime.diff(locked_until, now, :second))
        {:locked, seconds}

      _ ->
        :unlocked
    end
  end

  defp clear_failed_logins(%User{failed_login_count: 0, locked_until: nil} = user, _now), do: user

  defp clear_failed_logins(%User{} = user, _now) do
    from(u in User, where: u.id == ^user.id)
    |> Repo.update_all(
      set: [
        failed_login_count: 0,
        failed_login_first_at: nil,
        locked_until: nil,
        updated_at: DateTime.utc_now()
      ]
    )

    %{user | failed_login_count: 0, failed_login_first_at: nil, locked_until: nil}
  end

  # Failed login: increment the counter inside the rolling window. If we hit
  # the threshold, set `locked_until` with exponential backoff based on any
  # prior recent lock.
  defp record_failed_login(%User{} = user, now) do
    threshold = login_lockout_threshold()
    window_seconds = login_lockout_window_seconds()

    {new_count, new_first_at} = next_failure_window(user, now, window_seconds)

    if new_count >= threshold do
      duration = next_lockout_duration_seconds(user, now)
      locked_until = DateTime.add(now, duration, :second)

      from(u in User, where: u.id == ^user.id)
      |> Repo.update_all(
        set: [
          failed_login_count: new_count,
          failed_login_first_at: new_first_at,
          locked_until: locked_until,
          updated_at: now
        ]
      )
    else
      from(u in User, where: u.id == ^user.id)
      |> Repo.update_all(
        set: [
          failed_login_count: new_count,
          failed_login_first_at: new_first_at,
          updated_at: now
        ]
      )
    end

    :ok
  end

  defp next_failure_window(%User{failed_login_first_at: nil}, now, _window_seconds) do
    {1, now}
  end

  defp next_failure_window(
         %User{failed_login_count: count, failed_login_first_at: first_at},
         now,
         window_seconds
       ) do
    window_start = DateTime.add(now, -window_seconds, :second)

    case DateTime.compare(first_at, window_start) do
      :lt ->
        {1, now}

      _ ->
        {count + 1, first_at}
    end
  end

  # Compute the duration of the next lock. If the user has a recent prior lock
  # (within `:login_lockout_backoff_window_seconds`), double the previous
  # duration up to the configured cap.
  #
  # We derive "previous duration" from the existing locked_until value, treating
  # any locked_until set within the backoff window as evidence of a prior lock.
  # When locked_until is nil OR older than the backoff window, start at the
  # initial duration.
  defp next_lockout_duration_seconds(%User{locked_until: nil}, _now),
    do: login_lockout_duration_seconds()

  defp next_lockout_duration_seconds(%User{locked_until: prior_lock} = user, now) do
    backoff_window = login_lockout_backoff_window_seconds()
    horizon = DateTime.add(now, -backoff_window, :second)

    if DateTime.compare(prior_lock, horizon) == :gt do
      prior_duration =
        if user.failed_login_first_at do
          max(
            login_lockout_duration_seconds(),
            DateTime.diff(prior_lock, user.failed_login_first_at, :second)
          )
        else
          login_lockout_duration_seconds()
        end

      min(prior_duration * 2, login_lockout_max_duration_seconds())
    else
      login_lockout_duration_seconds()
    end
  end

  defp login_lockout_threshold,
    do: Application.get_env(:core, :login_lockout_threshold, 10)

  defp login_lockout_window_seconds,
    do: Application.get_env(:core, :login_lockout_window_seconds, 600)

  defp login_lockout_duration_seconds,
    do: Application.get_env(:core, :login_lockout_duration_seconds, 900)

  defp login_lockout_max_duration_seconds,
    do: Application.get_env(:core, :login_lockout_max_duration_seconds, 7_200)

  defp login_lockout_backoff_window_seconds,
    do: Application.get_env(:core, :login_lockout_backoff_window_seconds, 86_400)

  defp check_email_confirmed(%User{email_confirmed: true}), do: :ok
  defp check_email_confirmed(%User{}), do: {:error, :email_unconfirmed}

  @doc """
    Updates the profile_visibility setting for a user.
    Accepts "platform" or "owner". Returns {:error, changeset} for invalid values.
  """
  @spec update_profile_visibility(binary(), String.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_profile_visibility(user_id, visibility) do
    existing = get_user!(user_id)
    old_visibility = existing.profile_visibility

    result =
      existing
      |> profile_visibility_changeset(%{profile_visibility: visibility})
      |> Repo.update()

    case result do
      {:ok, user} ->
        Stacks.Visibility.emit_profile_visibility_change(old_visibility, visibility)

        Events.emit_safe(%{
          event_type: "user.profile_visibility_changed",
          aggregate_type: "user",
          aggregate_id: user.id,
          payload: %{visibility: visibility}
        })

        %{"user_id" => user.id, "new_visibility" => visibility}
        |> VisibilityRecapJob.new()
        |> Oban.insert()

        {:ok, user}

      error ->
        error
    end
  end

  @doc """
    Updates the display_name and website_url for a user.
    To change email, supply `email:` and `current_password:` — the current password
    is verified before the email is updated.
  """
  @spec update_profile(User.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | :invalid_password | :argon2_busy}
  def update_profile(%User{} = user, attrs) do
    if email_change?(user, attrs) do
      update_profile_with_email(user, attrs)
    else
      changeset = profile_changeset(user, attrs)

      changeset
      |> Repo.update()
      |> tap_emit_profile_updated()
      |> tap_emit_handle_claimed(changeset)
    end
  end

  defp email_change?(%User{email: current}, attrs) do
    case Map.get(attrs, "email") do
      nil -> false
      incoming -> normalise_email(incoming) != normalise_email(current)
    end
  end

  defp normalise_email(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalise_email(value), do: value

  defp tap_emit_handle_claimed({:ok, _user} = result, changeset) do
    if Ecto.Changeset.get_change(changeset, :handle) do
      :telemetry.execute([:stacks, :handle, :claimed], %{count: 1}, %{})
    end

    result
  end

  defp tap_emit_handle_claimed(error, _changeset), do: error

  defp update_profile_with_email(user, attrs) do
    with :ok <- verify_password(user, Map.get(attrs, "current_password")) do
      changeset = profile_changeset(user, attrs)

      Multi.new()
      |> Multi.update(:profile, changeset)
      |> Multi.update(:email, fn %{profile: u} ->
        email_changeset(u, %{"email" => attrs["email"]})
      end)
      |> Multi.run(:emit_event, fn _repo, %{email: u} ->
        Events.emit_safe(%{
          event_type: "user.profile_updated",
          aggregate_type: "user",
          aggregate_id: u.id,
          payload: %{}
        })

        {:ok, u}
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{email: u}} -> tap_emit_handle_claimed({:ok, u}, changeset)
        {:error, _, reason, _} -> {:error, reason}
      end
    end
  end

  defp tap_emit_profile_updated({:ok, user} = result) do
    Events.emit_safe(%{
      event_type: "user.profile_updated",
      aggregate_type: "user",
      aggregate_id: user.id,
      payload: %{}
    })

    result
  end

  defp tap_emit_profile_updated(error), do: error

  @doc """
    Updates the country_code and city for a user. Emits `user.location_updated`
    event with a UUID-only payload — the city/country_code are PII and are read
    back from the user record by consumers (see
    `Stacks.Discovery.Handlers.LocationUpdatedHandler`).
  """
  @spec update_location(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_location(%User{} = user, attrs) do
    result =
      user
      |> location_changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        Events.emit_safe(%{
          event_type: "user.location_updated",
          aggregate_type: "user",
          aggregate_id: updated.id,
          payload: %{}
        })

        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
    Changes the password for a user. Verifies `current_password` with Argon2 before
    applying the new password. Returns `{:error,:invalid_password}` on mismatch.
  """
  @spec change_password(User.t(), String.t(), String.t()) ::
          {:ok, User.t()}
          | {:error, :invalid_password | :argon2_busy}
          | {:error, Ecto.Changeset.t()}
  def change_password(%User{} = user, current_password, new_password) do
    with :ok <- verify_password(user, current_password),
         changeset <- password_length_changeset(user, new_password),
         true <- changeset.valid? || {:error, changeset},
         {:ok, hash} <- pool_hash_password(new_password) do
      result =
        user
        |> Ecto.Changeset.change(%{password_hash: hash})
        |> Repo.update()

      case result do
        {:ok, updated} ->
          Events.emit_safe(%{
            event_type: "user.password_changed",
            aggregate_type: "user",
            aggregate_id: updated.id,
            payload: %{}
          })

          {:ok, updated}

        error ->
          error
      end
    end
  end

  @doc """
    Updates notification preferences for a user.
  """
  @spec update_notifications(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_notifications(%User{} = user, attrs) do
    result =
      user
      |> notifications_changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        Events.emit_safe(%{
          event_type: "user.notifications_updated",
          aggregate_type: "user",
          aggregate_id: updated.id,
          payload: %{}
        })

        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
    Returns the current onboarding status for a user.

    Returns `%{steps: %{profile: bool, privacy: bool},
                completed: bool, next_step: step_name | nil}`.
  """
  @spec onboarding_status(binary()) :: map()
  def onboarding_status(user_id) do
    user = get_user!(user_id)
    steps = normalize_steps(user.onboarding_steps)
    completed = Enum.all?(@valid_onboarding_steps, &Map.get(steps, &1, false))

    next =
      Enum.find(@onboarding_step_order, fn step ->
        not Map.get(steps, step, false)
      end)

    %{steps: steps, completed: completed, next_step: next}
  end

  @doc """
    Marks a single onboarding step as completed for a user. Idempotent — completing
    an already-completed step is a no-op and returns `{:ok, user}`.

    Returns `{:ok, user}` or `{:error,:invalid_step}`.
  """
  @spec complete_onboarding_step(binary(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_step}
  def complete_onboarding_step(user_id, step) when is_binary(step) do
    if step in @valid_onboarding_steps do
      user = get_user!(user_id)
      current = normalize_steps(user.onboarding_steps)
      updated = Map.put(current, step, true)

      case user |> onboarding_steps_changeset(%{onboarding_steps: updated}) |> Repo.update() do
        {:ok, saved} -> {:ok, Repo.reload!(saved)}
        error -> error
      end
    else
      {:error, :invalid_step}
    end
  end

  @doc """
    Resets all onboarding steps to false, allowing the user to re-enter the
    onboarding flow from Settings.

    Returns `{:ok, user}`.
  """
  @spec reset_onboarding(binary()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def reset_onboarding(user_id) do
    empty = Map.new(@valid_onboarding_steps, fn step -> {step, false} end)

    case user_id
         |> get_user!()
         |> onboarding_steps_changeset(%{onboarding_steps: empty})
         |> Repo.update() do
      {:ok, saved} -> {:ok, Repo.reload!(saved)}
      error -> error
    end
  end

  @doc """
    Opens a token family at login, or advances its live token on refresh
    rotation. Idempotent upsert on `family_id`: replaces `current_jti` /
    `previous_jti` / `rotated_at`, preserves `session_started_at`, `user_id`,
    `revoked_at`. A missing family (legacy session) is created lazily — bound
    from now rather than locking the user out. `previous_jti` + `rotated_at`
    give the reuse gate its rotation grace window.
  """
  def rotate_token_family(attrs) do
    %AuthTokenFamily{}
    |> AuthTokenFamily.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:current_jti, :previous_jti, :rotated_at, :updated_at]},
      conflict_target: :family_id
    )
  end

  @doc """
    Reuse-detection gate, called on EVERY authenticated request
    (`Guardian.verify_claims/2`). `:ok` when the `jti` is the family's live
    token; `{:error,:session_revoked}` for a missing/revoked family;
    `{:error,:token_reuse_detected}` for a superseded `jti` in a live family —
    which revokes the WHOLE family and burns all the user's guardian tokens.
    The revoke-on-reuse write is idempotent and fails CLOSED: DB errors map to
    a 401 (`:family_check_failed`), never a crash.
  """
  @spec check_token_family(binary(), binary(), binary()) ::
          :ok | {:error, :session_revoked | :token_reuse_detected | :family_check_failed}
  def check_token_family(family_id, jti, sub)
      when is_binary(family_id) and is_binary(jti) and is_binary(sub) do
    case Repo.get(AuthTokenFamily, family_id) do
      nil ->
        {:error, :session_revoked}

      %AuthTokenFamily{revoked_at: revoked} when not is_nil(revoked) ->
        {:error, :session_revoked}

      %AuthTokenFamily{} = family ->
        classify_live_family(family, jti, sub)
    end
  rescue
    error ->
      Logger.error("check_token_family failed (failing closed): #{inspect(error)}")
      {:error, :family_check_failed}
  end

  def check_token_family(_family_id, _jti, _sub), do: {:error, :session_revoked}

  defp classify_live_family(%AuthTokenFamily{} = family, jti, sub) do
    cond do
      to_string(family.user_id) != sub ->
        {:error, :session_revoked}

      family.current_jti == jti ->
        :ok

      within_rotation_grace?(family, jti) ->
        :ok

      true ->
        revoke_family_and_burn(family)

        :telemetry.execute([:stacks, :auth, :refresh, :reuse_detected], %{count: 1}, %{})

        {:error, :token_reuse_detected}
    end
  end

  @doc """
    Revoke a single token family by marking `revoked_at` (idempotent).

    Used by logout: any token sharing this `family_id` — including an attacker's
    already-rotated chain — is rejected at the `verify_claims` gate on next use.
    Returns `{:ok, revoked_count}` where the count is 0 if it was already revoked.
  """
  @spec revoke_token_family(binary()) :: {:ok, non_neg_integer()}
  def revoke_token_family(family_id) when is_binary(family_id) do
    now = DateTime.utc_now()

    {count, _} =
      from(f in AuthTokenFamily, where: f.family_id == ^family_id and is_nil(f.revoked_at))
      |> Repo.update_all(set: [revoked_at: now, updated_at: now])

    {:ok, count}
  end

  @doc """
    Revoke ALL of a user's sessions ("log out everywhere").

    Marks every live family of the user `revoked_at` AND deletes every one of the
    user's `guardian_tokens` rows (`destroy_by_sub`), so no existing access token
    survives. Used on password change. Idempotent.
  """
  @spec revoke_all_user_sessions(binary()) :: :ok
  def revoke_all_user_sessions(user_id) do
    now = DateTime.utc_now()

    from(f in AuthTokenFamily, where: f.user_id == ^user_id and is_nil(f.revoked_at))
    |> Repo.update_all(set: [revoked_at: now, updated_at: now])

    GuardianDbToken.destroy_by_sub(to_string(user_id))

    :ok
  end

  defp within_rotation_grace?(%AuthTokenFamily{previous_jti: prev, rotated_at: rotated_at}, jti)
       when is_binary(prev) and not is_nil(rotated_at) and prev == jti do
    DateTime.diff(DateTime.utc_now(), rotated_at, :second) <= rotation_grace_seconds()
  end

  defp within_rotation_grace?(_family, _jti), do: false

  defp rotation_grace_seconds do
    :core
    |> Application.get_env(:session_rotation_grace, {20, :second})
    |> Duration.to_seconds()
  end

  defp revoke_family_and_burn(%AuthTokenFamily{} = family) do
    now = DateTime.utc_now()

    from(f in AuthTokenFamily, where: f.family_id == ^family.family_id)
    |> Repo.update_all(set: [revoked_at: now, updated_at: now])

    GuardianDbToken.destroy_by_sub(to_string(family.user_id))

    :ok
  end

  defp normalize_steps(nil), do: Map.new(@valid_onboarding_steps, &{&1, false})

  defp normalize_steps(steps) when is_map(steps) do
    Map.new(@valid_onboarding_steps, fn step ->
      {step, Map.get(steps, step, false) == true}
    end)
  end

  defp verify_password(%User{password_hash: hash}, current_password)
       when is_binary(current_password) do
    case ArgonPool.run(fn -> Argon2.verify_pass(current_password, hash) end) do
      true -> :ok
      false -> {:error, :invalid_password}
      {:error, :argon2_busy} -> {:error, :argon2_busy}
    end
  end

  defp verify_password(_user, _), do: {:error, :invalid_password}

  defp password_length_changeset(user, password) do
    user
    |> cast(%{password: password}, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, message: "must be at least 8 characters")
  end

  defp pool_hash_password(password) do
    case ArgonPool.run(fn -> Argon2.hash_pwd_salt(password) end) do
      hash when is_binary(hash) -> {:ok, hash}
      {:error, _} = err -> err
    end
  end

  defp maybe_assign_owner_role(attrs) do
    if Repo.aggregate(User, :count, :id) == 0 do
      put_role(attrs, "owner")
    else
      attrs
    end
  end

  defp put_role(attrs, role) when is_map_key(attrs, :email), do: Map.put(attrs, :role, role)

  defp put_role(attrs, role), do: Map.put(attrs, "role", role)
end
