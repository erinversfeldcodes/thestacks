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
  alias Stacks.Accounts.ReservedHandles
  alias Stacks.Accounts.User
  alias Stacks.Duration
  alias Stacks.Events
  alias Stacks.GDPR.Deletion
  alias Stacks.Social.UserBlock
  alias Stacks.Workers.VisibilityRecapJob

  # ---------------------------------------------------------------------------
  # Changeset functions (migrated from User schema for codegen compatibility)
  # ---------------------------------------------------------------------------

  # An email-confirmation link (and therefore an unverified account) lives 24h
  # after creation. Single source of truth: `Stacks.Email.confirm_email/1` uses
  # this for the token's `max_age`, and `ExpiredUnverifiedAccountsJob` uses it to
  # reap accounts whose link has expired. See docs/runbooks/gdpr-erase-user.md
  # (erasure) and the daily crontab in config/config.exs.
  @unverified_account_ttl_seconds 24 * 60 * 60

  @registration_required_fields [:email, :password]
  # `:age_verified` is intentionally NOT castable from user input (ADR-020):
  # self-declaration is gone; it is set only by Stacks.AgeVerification.
  @registration_optional_fields [:display_name, :role, :profile_visibility]

  # The self-declared "verify your age" onboarding step was dropped (ADR-020).
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
    |> cast(attrs, [:display_name, :website_url, :handle])
    |> drop_blank_handle_change()
    |> validate_length(:website_url, max: 500)
    # No-op unless :handle is being changed — keeps other profile updates unaffected.
    |> validate_handle()
  end

  # An empty/blank handle param casts to a nil change on the NOT NULL handle
  # column. validate_handle/1's validators skip nil changes, so without this the
  # nil reaches the UPDATE and violates the NOT NULL constraint (Postgrex 23502 →
  # 500). A real handle change is never to nil, so a nil handle change
  # unambiguously means "absent/blank input" — drop it so the save is a
  # no-handle-change (preserving the #211 validation path for real changes).
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

  # Downcase-on-write (#335 D4). `get_user_by_email/1` has always downcased its
  # ARGUMENT before an exact match, so an address stored with any upper-case
  # character produced an account nobody could log into — the sign-up succeeded
  # and every subsequent login failed. Normalising the stored value is the half
  # that was missing; `users_lower_email_index` (20260730200500) is the half that
  # stops two accounts sharing one address in different cases. Runs AFTER
  # `validate_format/3` so whitespace is still rejected outright rather than
  # silently trimmed into acceptance — `normalise_email/1`'s trim is then a
  # no-op here, kept only so the stored form and the comparison form in
  # `email_change?/2` are produced by one function.
  #
  # Both unique_constraint/2 calls above are needed: the exact-match
  # `users_email_index` is what a normalised duplicate actually violates, and
  # naming `users_lower_email_index` as well means a row that somehow reaches the
  # functional index (a direct put_change, a future write path) still comes back
  # as a changeset error rather than a raised Postgrex error.
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

  # ---------------------------------------------------------------------------
  # Public URL handle (/u/:handle) — #211
  # ---------------------------------------------------------------------------

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

  # Auto-assign a handle at registration when none is present, so every user has
  # a reachable /u/:handle. Users can change it later in settings (#212).
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
  valid after creation. The confirmation token's `max_age` and the
  expired-account reaper both key off this one value.
  """
  @spec unverified_account_ttl_seconds() :: pos_integer()
  def unverified_account_ttl_seconds, do: @unverified_account_ttl_seconds

  @doc """
  IDs of accounts whose email-confirmation link has expired: never confirmed and
  created more than `unverified_account_ttl_seconds/0` ago. Used by
  `Stacks.Workers.ExpiredUnverifiedAccountsJob` to reap abandoned signups.

  `now` is injectable for deterministic tests.
  """
  @spec expired_unverified_ids(DateTime.t()) :: [binary()]
  def expired_unverified_ids(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@unverified_account_ttl_seconds, :second)

    Repo.all(
      from u in User,
        where: u.email_confirmed == false and u.created_at < ^cutoff,
        select: u.id
    )
  end

  @doc """
  People search for the discovery surface (US-10.5.4).

  Returns up to #{20} users whose `display_name` matches `term` (case-insensitive
  `ILIKE`), restricted to **discoverable** profiles (`profile_visibility =
  "platform"`) and excluding any user blocked in **either** direction relative to
  `viewer_id`.

  The discoverability privacy rule is enforced **in SQL**, never by serializer
  redaction: a ghost (`profile_visibility = "owner"`) or a blocked user never
  enters the result set. When `viewer_id` is `nil` (unauthenticated) there is no
  viewer to block against, so only the `platform` filter applies.

  A blank/whitespace-only term returns `[]` (no query).
  """
  @search_limit 20
  @spec search_users(String.t(), binary() | nil) :: [User.t()]
  def search_users(term, viewer_id \\ nil)

  def search_users(term, viewer_id) when is_binary(term) do
    trimmed = String.trim(term)

    if trimmed == "" do
      []
    else
      # Compare against `lower(display_name)` (not raw `display_name`) so the
      # GIN trigram index on `lower(display_name)` (migration
      # 20260715120000_add_display_name_trgm_index) is usable — a leading-wildcard
      # ILIKE otherwise forces a sequential scan (Issue #222). Lowercasing both
      # sides is result-equivalent to the previous `ILIKE display_name`: ILIKE is
      # already case-insensitive, so `lower(display_name) ILIKE lower(pattern)`
      # matches exactly the same rows.
      pattern = "%#{escape_like(String.downcase(trimmed))}%"

      # Discoverability follows the Audience ladder (#225): a signed-in searcher
      # discovers "Members" (platform) AND public profiles; an ANONYMOUS searcher
      # discovers ONLY public profiles — platform is signed-in-only, so a logged-out
      # visitor must not even learn a Members profile exists (they'd 404 on it).
      # owner/group profiles are never discoverable via search.
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

  # Anti-join on op.user_blocks in BOTH directions. NOT EXISTS keeps the
  # exclusion in the result set (never a post-filter). No viewer → no block
  # filter (ghosts are still excluded by the discoverability filter above).
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

  # Escape ILIKE metacharacters so a literal % or _ in the term is not treated
  # as a wildcard.
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
  Registers a new user. The first user on the platform receives the `owner` role.

  The user is created with `email_confirmed: false` and a confirmation token.
  A confirmation email is sent via `EmailConfirmationHandler` (event-driven)
  and the caller receives `{:ok, user}` where `user.email_confirmed == false`.
  The user must confirm their email before they can authenticate.
  """
  @spec register(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register(attrs) do
    # Reap abandoned signups on the way in, so this does not depend on a nightly job.
    #
    # `ExpiredUnverifiedAccountsJob` was the only thing erasing accounts that never
    # confirmed their email, which made a cron entry the sole guarantee for a *retention*
    # obligation — and nothing user-triggered could substitute, because the person who
    # abandoned a signup by definition never comes back. With the platform scaling to
    # zero, that job may not fire at all.
    #
    # Registration is the right moment for two reasons. It is the event most correlated
    # with signup abandonment, so the work arrives roughly in proportion to the debt.
    # And an abandoned account currently *blocks* a real one: someone re-registering the
    # same address gets "email has already been taken" for an account nobody owns.
    reap_abandoned_signups(attrs)

    attrs = maybe_assign_owner_role(attrs)
    do_register(attrs, 2)
  end

  # Erases the abandoned signup for this email, if there is one, plus a small batch of
  # others.
  #
  # Bounded and synchronous-but-cheap: an unverified account has never logged in, so it
  # carries no bookshelves, placements, comments or sessions. Failures are swallowed —
  # a registration must not fail because someone else's abandoned signup could not be
  # erased. The nightly job stays as a backstop.
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
        actor: "system:registration_reap"
      )
    end)
  rescue
    error ->
      Logger.warning("Accounts.register: could not reap abandoned signups: #{inspect(error)}")
      :ok
  end

  # Deliberately ignores the TTL: if someone is registering this exact address, the
  # earlier unconfirmed attempt is abandoned regardless of how recent it is, and holding
  # the address hostage for 24 hours serves nobody.
  defp abandoned_id_for_email(nil), do: []

  defp abandoned_id_for_email(email) do
    normalised = email |> to_string() |> String.downcase() |> String.trim()

    Repo.all(
      from u in User,
        where: fragment("lower(?)", u.email) == ^normalised and u.email_confirmed == false,
        select: u.id
    )
  end

  # The handle is auto-assigned at registration (maybe_put_handle) and its only
  # failure mode is the astronomically-rare lower(handle) unique collision. Since
  # the user never chose it, regenerate (a fresh random suffix) and retry rather
  # than surfacing an inexplicable "handle has already been taken" for a handle
  # they cannot see.
  defp do_register(attrs, retries_left) do
    Multi.new()
    |> Multi.insert(:user, registration_changeset(%User{}, attrs))
    |> Multi.run(:set_confirmation, fn _repo, %{user: user} ->
      # Generate the FINAL, verifiable confirmation token synchronously so it is
      # stable the moment registration commits. It is a Phoenix.Token signed with
      # the "email_confirm" salt to match Stacks.Email.confirm_email/1's verify;
      # the async EmailConfirmationHandler only DELIVERS this token, it never
      # regenerates it. Previously this stored a raw random token that the handler
      # later overwrote with a Phoenix.Token — a register↔handler race where a
      # token read before the handler ran (E2E helper, or a fast client) failed
      # verification and redirected to /confirm-email/error.
      token = Phoenix.Token.sign(CoreWeb.Endpoint, "email_confirm", user.id)

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
    |> Repo.transaction()
    |> case do
      {:ok, %{set_confirmation: user}} ->
        {:ok, user}

      {:error, :user, changeset, _} ->
        if retries_left > 0 and handle_collision?(changeset) do
          do_register(attrs, retries_left - 1)
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
  Authenticates a user by email and password.

  Returns `{:ok, user}` on success. On failure, returns one of:
  - `{:error, :invalid_credentials}` — wrong email or password
  - `{:error, :email_unconfirmed}` — valid credentials but email not confirmed
  - `{:error, {:account_locked, retry_after_seconds}}` — per-account lockout active
  - `{:error, :argon2_busy}` — Argon2 worker pool exhausted

  Order of checks (Issue #161):
  1. Look up user by email. Unknown email → constant-time dummy-hash branch
     (`Argon2.no_user_verify/0`) so attackers cannot enumerate emails by timing.
  2. If `locked_until` is in the future → return `:account_locked` immediately,
     WITHOUT entering the ArgonPool. Locked attempts must not consume pool
     slots or attacker-controllable Argon2 work.
  3. Otherwise run the Argon2 verify. On failure, increment the per-account
     failure counter (rolling window) and possibly set a new `locked_until`
     with exponential backoff. On success, zero the counter and clear any
     stale `locked_until`.
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
    # Run a dummy hash through the pool to prevent timing-based email enumeration.
    # We always return :invalid_credentials regardless of pool status — a busy pool
    # is a marginally faster response but not meaningfully exploitable.
    _ = ArgonPool.run(fn -> Argon2.no_user_verify() end)
    {:error, :invalid_credentials}
  end

  defp check_password(user, password) do
    now = DateTime.utc_now()

    # CRITICAL: lockout check is performed BEFORE ArgonPool. A locked
    # account must not be able to consume pool slots, and we must not
    # leak whether the attacker-controlled password is right or wrong
    # while the account is locked.
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

  # ---------------------------------------------------------------------------
  # Per-account login lockout (Issue #161)
  # ---------------------------------------------------------------------------

  @spec lockout_status(User.t(), DateTime.t()) :: :unlocked | {:locked, pos_integer()}
  defp lockout_status(%User{locked_until: nil}, _now), do: :unlocked

  defp lockout_status(%User{locked_until: locked_until}, now) do
    case DateTime.compare(locked_until, now) do
      :gt ->
        # max(1, diff) so we never return 0 (would defeat the point of
        # retry_after) and never negative (clock skew at the boundary).
        seconds = max(1, DateTime.diff(locked_until, now, :second))
        {:locked, seconds}

      _ ->
        # Lock is in the past — treat as expired/unlocked. The row will
        # be cleared on the next successful login (or stays as historical
        # data we can use for backoff calculations).
        :unlocked
    end
  end

  # Successful login: reset counter, clear lock, clear window start.
  # Returns the updated user (or the original on unexpected failure — caller
  # already has a valid authentication).
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

  # Compute the new {count, first_at} for the rolling failure window.
  # - If there's no prior failure or the prior window has expired, start fresh
  #   at count=1.
  # - Otherwise increment the existing count, keeping the original first_at so
  #   the window is anchored to the FIRST failure.
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
        # Prior window has elapsed — fresh window.
        {1, now}

      _ ->
        # Still inside the window — increment.
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
      # The previous lock was within the backoff window — compound.
      # We can't know the prior duration exactly without a history table,
      # so derive it from the failed_login_first_at anchor: the prior
      # duration is approximately (prior_lock - failed_login_first_at).
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
      # Prior lock is too old to count — restart at the initial duration.
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

  # A payload carries an email CHANGE only when it includes an "email" key whose
  # normalised value differs from the user's current email. The settings UI sends
  # the current email on every profile save, so a same-email payload must NOT be
  # treated as a change (that would demand current_password on ordinary profile
  # edits). auth resolves identity case-insensitively (get_user_by_email/1
  # downcases), so we compare downcased/trimmed on both sides. Storage now
  # matches: `downcase_email/1` normalises on every write path (#335 D4), closing
  # the inconsistency flagged in the #126 report. The comparison stays normalised
  # anyway so a legacy mixed-case row still reads as "no change".
  defp email_change?(%User{email: current}, attrs) do
    case Map.get(attrs, "email") do
      nil -> false
      incoming -> normalise_email(incoming) != normalise_email(current)
    end
  end

  defp normalise_email(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalise_email(value), do: value

  # NO-PII: emit ONLY the fact that a handle was set/changed — never the handle
  # value (public but unbounded cardinality; telemetry is warehouse-adjacent).
  # Fires only on a successful update whose changeset actually changed `:handle`.
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
        # UUID-only payload: display_name is PII and must not enter
        # op.event_log (GDPR — Issue #121). Consumers read the current
        # profile from the user record via aggregate_id.
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
    # UUID-only payload: display_name is PII and must not enter op.event_log
    # (GDPR — Issue #121). Consumers read the current profile from the user
    # record via aggregate_id.
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
        # UUID-only payload: city + country_code are PII and must not enter
        # op.event_log (GDPR — Issue #121).
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
  applying the new password. Returns `{:error, :invalid_password}` on mismatch.
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
        # UUID-only payload: notification preferences are personal data and must
        # not enter op.event_log (GDPR — Issue #121). Consumers read the current
        # preferences from the user record via aggregate_id.
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

  Returns `{:ok, user}` or `{:error, :invalid_step}`.
  """
  @spec complete_onboarding_step(binary(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_step}
  def complete_onboarding_step(user_id, step) when is_binary(step) do
    if step in @valid_onboarding_steps do
      user = get_user!(user_id)
      current = normalize_steps(user.onboarding_steps)
      updated = Map.put(current, step, true)

      case user |> onboarding_steps_changeset(%{onboarding_steps: updated}) |> Repo.update() do
        # Repo.reload! is required: onboarding_completed is a GENERATED ALWAYS AS column.
        # Ecto does not fetch generated columns automatically after an update — we must
        # reload to get the DB-computed value in the returned struct.
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
      # Repo.reload! is required: onboarding_completed is a GENERATED ALWAYS AS column.
      # Ecto does not fetch generated columns automatically after an update — we must
      # reload to get the DB-computed value in the returned struct.
      {:ok, saved} -> {:ok, Repo.reload!(saved)}
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Refresh-token families (Issue #179, Phase 2a)
  #
  # A family is a rotation chain, opened at login and updated on every refresh.
  # `current_jti` tracks the single live access token of the session so a later
  # phase can detect reuse of a superseded token and revoke the whole family.
  # ---------------------------------------------------------------------------

  @doc """
  Open a family at login, or advance a family's live token on refresh rotation.

  At login the caller passes a freshly generated `family_id`, so the upsert is
  a plain insert; the caller treats a failure as fatal — a token whose family
  row did not persist would violate the invariant that every live access token
  is tracked by exactly one family.

  Idempotent upsert keyed on `family_id`: an existing family has its
  `current_jti`, `previous_jti`, `rotated_at` (and `updated_at`) replaced —
  `session_started_at`, `user_id` and `revoked_at` are preserved. A missing
  family (a legacy session minted before families existed, or a direct-action
  test path) is created lazily so the session becomes tracked from now rather
  than locking the user out. This mirrors the Phase 1 `sst` policy of binding an
  untracked session from the current moment instead of treating it as invalid.

  The caller records the rotation grace metadata (Issue #180): `previous_jti` is
  the jti being superseded (the OLD `current_jti`) and `rotated_at` is now, so
  the reuse gate can honour the just-rotated old token for a short grace window.
  """
  def rotate_token_family(attrs) do
    %AuthTokenFamily{}
    |> AuthTokenFamily.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:current_jti, :previous_jti, :rotated_at, :updated_at]},
      conflict_target: :family_id
    )
  end

  # ---------------------------------------------------------------------------
  # Reuse detection + family revocation (Issue #179, Phase 2b)
  # ---------------------------------------------------------------------------

  @doc """
  Reuse-detection gate for a family-bearing access token.

  Called from `Stacks.Accounts.Guardian.verify_claims/2` on EVERY authenticated
  request. Returns:

    * `:ok` — the presented `jti` IS the family's live token (happy path).
    * `{:error, :session_revoked}` — the family is missing (already reaped or
      never opened) or has `revoked_at` set. Fail closed.
    * `{:error, :token_reuse_detected}` — a NON-current `jti` was presented in a
      still-live family. This is a superseded token being replayed (a stale tab,
      or a stolen already-rotated token). Response: revoke the WHOLE family
      (`revoked_at` + `destroy_by_sub` burns every one of the user's
      `guardian_tokens` rows, killing the live token too) and reject.

  The revoke on reuse is a WRITE performed inside verify_claims. It is
  idempotent (a second call sees the now-revoked family and returns
  `:session_revoked` without re-burning) and fails CLOSED: any DB error is
  logged and mapped to `{:error, :family_check_failed}` (a 401), never a crash,
  so a transient DB hiccup in the gate cannot 500 an authenticated request.
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

  # Classify a token against its live (non-revoked, existing) family.
  defp classify_live_family(%AuthTokenFamily{} = family, jti, sub) do
    cond do
      # Ownership guard (defense-in-depth): `family_id` is a signed claim, so a
      # cross-user family_id is not reachable today — but if `sub` and
      # `family_id` ever desync, reject WITHOUT burning the innocent owner's
      # family (a mismatched token must not revoke someone else's session).
      to_string(family.user_id) != sub ->
        {:error, :session_revoked}

      family.current_jti == jti ->
        :ok

      # Rotation grace window (Issue #180): the IMMEDIATELY-PREVIOUS token,
      # presented within `grace_seconds` of the rotation that superseded it, is a
      # benign in-flight / multi-tab race — NOT reuse. Honour it WITHOUT burning
      # and WITHOUT advancing current_jti. Applies ONLY to `previous_jti` (the
      # single immediate predecessor): an older token (2+ rotations back) has a
      # different jti and falls through to burn.
      within_rotation_grace?(family, jti) ->
        :ok

      true ->
        revoke_family_and_burn(family)

        # Refresh-token REUSE detected (Issue #237). A presented jti that is
        # neither the family's current token nor a within-grace predecessor
        # means a rotated/superseded refresh token was replayed — the
        # token-theft signal. We burned the whole family above; count it so any
        # non-zero value is alertable. NO PII in the metadata: no token, jti,
        # user-id, or IP (telemetry is warehouse-adjacent, GDPR).
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

  # Rotation grace predicate (Issue #180). True IFF the presented jti is the
  # family's immediate predecessor (`previous_jti`) AND that rotation happened no
  # more than `session_rotation_grace` seconds ago. Requires BOTH `previous_jti`
  # and `rotated_at` to be set (a never-rotated / legacy family has neither, so
  # this is always false and the caller burns as #179 intended). The window is
  # applied ONLY to `previous_jti`, never to an older jti.
  defp within_rotation_grace?(%AuthTokenFamily{previous_jti: prev, rotated_at: rotated_at}, jti)
       when is_binary(prev) and not is_nil(rotated_at) and prev == jti do
    DateTime.diff(DateTime.utc_now(), rotated_at, :second) <= rotation_grace_seconds()
  end

  defp within_rotation_grace?(_family, _jti), do: false

  # Grace window expressed as `{n, unit}` in config, converted to seconds here at
  # the check site.
  #
  # ⛔ This function's previous comment said it mirrored the AuthController
  # session-cap converter. It did not: its private unit table stopped at `:hour`,
  # so a `session_rotation_grace` of `{1, :day}` fell into the catch-all and was
  # honoured as ONE SECOND. `Stacks.Duration` carries the fail-safe (unknown unit
  # → seconds, so a misconfig fails toward LESS grace) that made the catch-all
  # right, and the units that made it wrong.
  defp rotation_grace_seconds do
    :core
    |> Application.get_env(:session_rotation_grace, {20, :second})
    |> Duration.to_seconds()
  end

  # Reuse response: mark the family revoked and burn all the user's live tokens.
  # `update_all` (not scoped to unrevoked) is fine — re-stamping an already-set
  # revoked_at is harmless and keeps the primitive branch-free.
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

  # Mirrors the caller's key style rather than always writing a string key.
  #
  # It used to `Map.put(attrs, "role", …)` unconditionally, so atom-keyed attrs became
  # a mixed-key map and Ecto refused to cast it: `expected params to be a map with
  # atoms or string keys, got a map with mixed keys`. That only bites when the new user
  # is the *first* one — the owner branch — which is why the controller (string keys
  # from JSON) never hit it, and why nothing noticed.
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
