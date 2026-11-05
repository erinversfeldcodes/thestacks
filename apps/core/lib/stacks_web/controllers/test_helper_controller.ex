defmodule StacksWeb.TestHelperController do
  @moduledoc """
      Test-only E2E endpoints. Deliberately UNAUTHENTICATED — the suite calls
      them before it has a session. The sole gate is `Plugs.E2ETestHelper`
      (404 unless `STACKS_E2E_TEST_HELPERS=1`); user-scoped helpers are further
      restricted to `.test`-domain emails, which no real account can hold.
  """

  use CoreWeb, :controller

  import StacksWeb.ChangesetHelpers, only: [format_errors: 1]

  alias Stacks.Accounts
  alias Stacks.Accounts.Guardian
  alias Stacks.Admin.SessionContext
  alias Stacks.AgeVerification
  alias Stacks.Blog
  alias Stacks.Books
  alias Stacks.Email
  alias Swoosh.Adapters.Local.Storage.Memory

  require Logger

  @e2e_email_domain "@thestacks.test"

  @e2e_seed_isbn_prefix "97899999"

  @doc """
      GET /api/test/confirmation-token?email=<email>

      Returns the raw email-confirmation token so the suite can drive the
      confirm-email flow without real delivery. `200 {"token":...}` for a
      test-domain user holding a token; `404` for anything out of scope.
  """
  def confirmation_token(conn, %{"email" => email}) when is_binary(email) do
    with true <- e2e_test_email?(email),
         %{email_confirmation_token: token} when is_binary(token) <-
           Accounts.get_user_by_email(email) do
      json(conn, %{token: token})
    else
      _ -> not_found(conn)
    end
  end

  def confirmation_token(conn, _params), do: not_found(conn)

  @doc """
      GET /api/test/sent-emails?email=<email>

      Returns emails delivered to the address from the Swoosh **Local** (in-memory)
      mailbox, so the suite can prove the whole send path, not just that a DB token
      exists. `.test`-domain addresses only; exact-recipient match — real users'
      mail can never surface. `200 {"emails": [...]}` newest first (empty when the
      stack uses a real provider); `404` out of scope.
  """
  def sent_emails(conn, %{"email" => email}) when is_binary(email) do
    if e2e_test_email?(email) do
      target = String.downcase(email)

      emails =
        Memory.all()
        |> Enum.filter(fn mail -> email_addressed_to?(mail, target) end)
        |> Enum.map(fn mail ->
          %{
            to: Enum.map(mail.to, &address/1),
            subject: mail.subject,
            html_body: mail.html_body,
            text_body: mail.text_body
          }
        end)

      json(conn, %{mailbox_readable: mailbox_readable?(), emails: emails})
    else
      not_found(conn)
    end
  end

  def sent_emails(conn, _params), do: not_found(conn)

  defp mailbox_readable? do
    :core
    |> Application.get_env(Stacks.Email.Mailer, [])
    |> Keyword.get(:adapter) == Swoosh.Adapters.Local
  end

  defp email_addressed_to?(mail, target) do
    Enum.any?(mail.to, fn recipient -> String.downcase(address(recipient)) == target end)
  end

  defp address({_name, addr}), do: addr
  defp address(addr) when is_binary(addr), do: addr

  @doc """
      PUT /api/test/age-verification  body: {"email", "verified"}

      Sets or clears a user's age verification without a real KYC provider
      (production has none). `true` records via
      `AgeVerification.record_verification/3` with provider `"e2e_test_helper"`;
      `false` clears. `.test`-domain emails only; `200 {"ok": true}` or `404`.
  """
  def set_age_verification(conn, %{"email" => email, "verified" => verified})
      when is_binary(email) and is_boolean(verified) do
    with true <- e2e_test_email?(email),
         %{} = user <- Accounts.get_user_by_email(email),
         {:ok, _user} <- apply_verification(user, verified) do
      json(conn, %{ok: true})
    else
      _ -> not_found(conn)
    end
  end

  def set_age_verification(conn, _params), do: not_found(conn)

  @doc """
      DELETE /api/test/admin-sessions  body: {"email"}

      Revokes every live admin session the named operator holds, putting them
      back to "signed in, not elevated". `200 {"revoked": n}` or `404`.

      ⛔ **Why this exists, and why the E2E suite cannot do without it.** Admin
      elevation now lives on the server's session and survives a reload — which
      is the product behaviour — so a spec can no longer assume the sign-in gate
      appears on every load. Each spec that wants to drive the gate has to start
      from a known-unelevated state, and the only alternatives were a
      conditional "pass the gate if it happens to be showing" (a vacuous guard
      by this repo's own rule) or ordering dependencies between tests.

      ⚖️ **It can only ever reduce access**, which is why it carries no
      `.test`-domain restriction where its siblings do: those mint or grant
      something, so they are confined to throwaway accounts. This revokes, so
      the worst a misuse achieves is making an operator sign in again. It is
      still behind `STACKS_E2E_TEST_HELPERS` like every route in this scope.
  """
  def revoke_admin_sessions(conn, %{"email" => email}) when is_binary(email) do
    case Accounts.get_user_by_email(email) do
      %{} = user -> json(conn, %{revoked: SessionContext.revoke_all_for_user(user.id)})
      _ -> not_found(conn)
    end
  end

  def revoke_admin_sessions(conn, _params), do: not_found(conn)

  defp apply_verification(user, true),
    do: AgeVerification.record_verification(user, "e2e_test_helper", nil)

  defp apply_verification(user, false), do: AgeVerification.revoke(user)

  @mint_password "e2e-password"

  @doc """
      POST /api/test/session  body: {"email"?, "display_name"?}

      Mints a fresh CONFIRMED user + session token in one call, bypassing the
      shared `:auth` rate bucket. The token uses the exact `AuthController.login`
      path (Guardian + fresh `family_id` + `rotate_token_family/1`, failing closed).

      ⚠️ This endpoint MINTS AUTHENTICATION: the email MUST be in the reserved
      `.test` TLD (else plain 404, no user created), so a session can never be
      minted for a real account. `201 {email, token, user_id, display_name}`
      or `422 {errors}`.
  """
  def mint_session(conn, params) do
    email = Map.get(params, "email") || generated_mint_email()
    display_name = Map.get(params, "display_name", "E2E Minted User")

    with true <- e2e_test_email?(email),
         {:ok, user} <-
           Accounts.register(
             %{
               "email" => email,
               "password" => @mint_password,
               "display_name" => display_name
             },
             skip_invite_gate: true
           ),
         {:ok, user} <- Accounts.mark_confirmed(user) do
      issue_session(conn, user)
    else
      false ->
        not_found(conn)

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  @doc """
      POST /api/test/book-writing  body: {"email", "book_id", "title"?}

      Seeds a blog post with a VISIBLE manual book association so the spine
      bookmark-ribbon E2E is deterministic (production associates via an async LLM
      worker). Writes the same end state via `Blog.associate_book/3`. `.test`-domain
      emails only. `201 {ok, post_id, association_id}`, `404` out of scope,
      `422 {errors}`.
  """
  def seed_book_writing(conn, %{"email" => email, "book_id" => book_id} = params)
      when is_binary(email) and is_binary(book_id) do
    title = Map.get(params, "title", "E2E writing about a book")

    with true <- e2e_test_email?(email),
         %{} = user <- Accounts.get_user_by_email(email),
         {:ok, post} <-
           Blog.create_post(user, %{title: title, body: "Seeded by the E2E ribbon spec."}),
         {:ok, assoc} <- Blog.associate_book(post, book_id) do
      conn
      |> put_status(:created)
      |> json(%{ok: true, post_id: post.id, association_id: assoc.id})
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})

      _ ->
        not_found(conn)
    end
  end

  def seed_book_writing(conn, _params), do: not_found(conn)

  @doc """
      POST /api/test/book-description  body: {"title", "description", "isbn"?}

      Creates a NEW public single-edition book so `description_tsv` populates for
      the deep-search E2E. An omitted ISBN gets a checksum-valid one in the reserved
      E2E-seed block (`generate_valid_isbn13/0`), so seeded books are identifiable
      and can never masquerade as verified catalogue.

      ⚠️ The one helper that inserts PUBLIC catalogue rows past the ISBN Hard
      Gate's provider check — an accepted, bounded risk: reserved
      prefix, insert-only (never mutates shared rows), flag-gated. Writes no user
      data/PII. `201 {book_id, edition_id, isbn}` or `422 {errors}`.
  """
  def seed_book_description(conn, %{"title" => title, "description" => description} = params)
      when is_binary(title) and is_binary(description) do
    isbn = Map.get(params, "isbn") || generate_valid_isbn13()

    case Books.create(%{"isbn" => isbn, "title" => title, "description" => description}) do
      {:ok, book} ->
        conn
        |> put_status(:created)
        |> json(%{ok: true, book_id: book.id, title: book.title})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def seed_book_description(conn, _params), do: not_found(conn)

  defp generate_valid_isbn13 do
    serial =
      System.unique_integer([:positive])
      |> rem(10_000)
      |> Integer.to_string()
      |> String.pad_leading(4, "0")

    first12 = @e2e_seed_isbn_prefix <> serial
    digits = first12 |> String.graphemes() |> Enum.map(&String.to_integer/1)

    sum =
      digits
      |> Enum.with_index()
      |> Enum.reduce(0, fn {d, i}, acc -> acc + d * if(rem(i, 2) == 0, do: 1, else: 3) end)

    check = rem(10 - rem(sum, 10), 10)
    first12 <> Integer.to_string(check)
  end

  defp generated_mint_email do
    "e2e-mint-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}@thestacks.test"
  end

  @doc """
      GET /api/test/email-budget[?email=…]

      Reports the hourly email-send budget: both counts and both limits, from
      `Stacks.Email.budget/1`.

      ⛔ WHY THE HARNESS NEEDS THIS. "Forgot my password" and "resend
      confirmation" answer identically whether or not a letter was queued —
      deliberately, so neither can be used to discover whether an address has an
      account. A spec driving one of them therefore cannot tell a broken feature
      from a full bucket by reading the response, and **the suite is the thing
      that fills the bucket**: it registers a user per test and each
      registration queues a confirmation. Three local runs put 101 sends in an
      hour against a global limit of 100, and the three email specs then failed
      with "expected a password-reset email" — which reads as a product defect.

      ⚠️ Counts only, never an address or a subject, and the `email` parameter
      is held to the same `.test`-domain rule as every other helper here, so
      this cannot be turned into an account-existence oracle. 404 out of scope.
  """
  def email_budget(conn, params) do
    case Map.get(params, "email") do
      nil ->
        json(conn, Email.budget())

      email ->
        with true <- e2e_test_email?(email),
             %{} = user <- Accounts.get_user_by_email(email) do
          json(conn, Email.budget(user.id))
        else
          _ -> not_found(conn)
        end
    end
  end

  defp issue_session(conn, user) do
    fid = Ecto.UUID.generate()
    {:ok, token, claims} = Guardian.encode_and_sign(user, %{"family_id" => fid})

    family_attrs = %{
      family_id: fid,
      user_id: user.id,
      current_jti: claims["jti"],
      session_started_at: DateTime.from_unix!(claims["sst"])
    }

    case Accounts.rotate_token_family(family_attrs) do
      {:ok, _family} ->
        # ⛔ NO SET-COOKIE HERE, AND THE REASON IS WHAT THIS ENDPOINT IS FOR.
        # It fabricates a credential for an identity the caller will act as
        # SOMEWHERE ELSE — a browser context, a bearer header — which is a
        # different job from `POST /api/auth/login`, where the client doing the
        # logging in is the client that gets the session. This version did set
        # the cookie, through the real login's own helper, for the good reason
        # that a helper issuing a session differently from production is a
        # harness that passes while production is broken.
        #
        # ⚠️ MEASURED COST OF THAT FIDELITY: `AuthPipeline` installs the cookie
        # plug BEFORE `VerifyHeader`, so the cookie WINS when both are present.
        # A caller that mints two identities down one HTTP client — which is
        # the normal shape of a harness that needs an owner and a member — had
        # its second mint silently overwrite the first, and every later request
        # then acted as whoever was minted LAST no matter which bearer token it
        # carried. An owner inviting a member became that member inviting
        # themselves, and the refusal looked like a product fault in groups.
        #
        # ⚖️ So the response describes the credential and changes nothing about
        # who the caller is. The cookie's attributes still have exactly one
        # author — `SessionCookie` — and the harness that writes them by hand is
        # held to it by the attribute test in `session_cookie_test.exs`.
        conn
        |> put_status(:created)
        |> json(%{
          email: user.email,
          token: token,
          user_id: user.id,
          display_name: user.display_name
        })

      {:error, reason} ->
        Logger.error("rotate_token_family failed on E2E session mint: #{inspect(reason)}")
        revoke_minted_token(token)

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "internal_error"})
    end
  end

  defp revoke_minted_token(token) do
    case Guardian.revoke(token) do
      {:ok, _claims} -> :ok
      error -> Logger.warning("Guardian.revoke failed on mint fail-close: #{inspect(error)}")
    end
  end

  defp e2e_test_email?(email) do
    email
    |> String.downcase()
    |> String.ends_with?(@e2e_email_domain)
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found"})
  end
end
