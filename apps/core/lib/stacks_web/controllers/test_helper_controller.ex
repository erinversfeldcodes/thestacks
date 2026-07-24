defmodule StacksWeb.TestHelperController do
  @moduledoc """
  Test-only endpoints used by the E2E suite (Issue #124).

  These endpoints are UNAUTHENTICATED by design — the E2E suite calls them
  before it has a session (e.g. to drive the confirm-email flow without real
  email delivery). The sole gate is `StacksWeb.Plugs.E2ETestHelper`, which
  requires the `STACKS_E2E_TEST_HELPERS=1` server flag and returns 404
  otherwise. This controller therefore assumes the flag is on; it must never
  be routed without that plug in front of it.
  """

  use CoreWeb, :controller

  import StacksWeb.ChangesetHelpers, only: [format_errors: 1]

  alias Stacks.Accounts
  alias Stacks.Accounts.Guardian
  alias Stacks.AgeVerification
  alias Stacks.Blog
  alias Swoosh.Adapters.Local.Storage.Memory

  require Logger

  # Reserved test TLD (RFC 6761) used for ALL E2E/test accounts:
  #   - suite users:       e2e-<slug>@thestacks.test   (seeds.exs / helpers.ts suiteEmail)
  #   - registration users: <prefix>-<ts>-<rand>@thestacks.test (helpers.ts uniqueEmail)
  # A real, deliverable email address can NEVER be in the `.test` TLD, so scoping
  # the lookup to this domain guarantees a real user's activation token can never
  # be leaked — even when the flag is on for a public preview carrying real users.
  @e2e_email_domain "@thestacks.test"

  @doc """
  GET /api/test/confirmation-token?email=<email>

  Returns the raw `email_confirmation_token` for the given user so the E2E
  suite can exercise the confirm-email flow without real email delivery.

  Responds `200 {"token": "<token>"}` for an existing E2E/test-domain user that
  has a confirmation token, and `404` if the email is not an E2E/test-domain
  address, the user does not exist, or the user has no token. The not-found and
  out-of-scope cases are deliberately indistinguishable (both plain 404) so the
  endpoint is not a user-enumeration oracle for real accounts.

  The response body contains ONLY the token — no email, id, password data, or
  any other PII.
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

  Returns the transactional emails delivered to the given address from the
  Swoosh **Local** mailbox (the in-memory adapter used by the default preview /
  offline E2E stack), so the E2E suite can assert an email was actually SENT and
  extract the link it carries — proving the whole send path, not just that a DB
  token exists.

  Scoped to `@thestacks.test` emails ONLY, and only rows in the mailbox
  addressed to that exact address are returned — a real user's mail can never
  surface here, even on a public preview with the flag on. Returns
  `200 {"emails": [%{to, subject, html_body, text_body}]}` (most recent first),
  or `404` for any out-of-scope email.

  When the stack is configured with a real provider (Resend, e.g. a
  `preview-real-email` PR or prod), nothing lands in the Local mailbox and this
  returns an empty list — the helper is for the default Local preview.
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

      # `mailbox_readable` tells the E2E client whether reading this mailbox is
      # meaningful: only the Local adapter routes sends here. When a real
      # provider (Resend) is configured — e.g. a `preview-real-email` PR — mail
      # never lands in this in-memory store, so the client should SKIP rather
      # than fail on an (expectedly) empty mailbox.
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

  # Swoosh normalises recipients to `{name, address}` tuples, but tolerate a
  # bare address string too.
  defp address({_name, addr}), do: addr
  defp address(addr) when is_binary(addr), do: addr

  @doc """
  PUT /api/test/age-verification  body: {"email": <email>, "verified": <bool>}

  Sets (or clears) a user's age verification so the E2E suite can create a
  verified user without a real KYC provider (ADR-020 — production has no provider
  and no verified users). `verified: true` records a verification via
  `Stacks.AgeVerification.record_verification/3` with provider `"e2e_test_helper"`;
  `verified: false` revokes it.

  Scoped to `@thestacks.test` emails ONLY — a real user can never be in the
  reserved test TLD, so this can never flip a real account's age status even when
  the flag is on for a public preview. Responds `200 {"ok": true}` for an
  existing test-domain user, and a plain `404` for any out-of-scope email or
  unknown user (deliberately indistinguishable — not an enumeration oracle).
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

  defp apply_verification(user, true),
    do: AgeVerification.record_verification(user, "e2e_test_helper", nil)

  defp apply_verification(user, false), do: AgeVerification.revoke(user)

  # Shared, non-secret password for minted E2E users — matches E2E_PASSWORD in
  # e2e/tests/helpers.ts so a spec can still drive the real login form for a
  # minted account when it needs to.
  @mint_password "e2e-password"

  @doc """
  POST /api/test/session  body: {"email": <optional>, "display_name": <optional>}

  Provisions a fresh, CONFIRMED user and returns a ready-to-use session token
  in one call (Issue #192), so E2E specs can mint isolated throwaway users
  without going through `/auth/register` + `/auth/login` — both of which sit
  in the `:auth` rate bucket shared across the whole parallel suite.

  The token is minted via the exact same path `AuthController.login` uses
  (`Guardian.encode_and_sign/2` with a fresh `family_id` claim +
  `Accounts.open_token_family/1`, failing closed if the family row does not
  persist), so it is indistinguishable from a real login session token.

  Security posture: this endpoint MINTS AUTHENTICATION. Besides the
  `STACKS_E2E_TEST_HELPERS` router gate (404 when off), the email — supplied
  or defaulted — MUST be in the reserved `.test` E2E domain; anything else is
  a plain 404 and no user is created. A real, deliverable address can never be
  in the `.test` TLD, so a session can never be minted for a real account,
  even on a public preview with the flag on.

  Responds `201 {"email", "token", "user_id", "display_name"}` on success and
  `422 {"errors": ...}` when the user cannot be created (e.g. email taken).
  """
  def mint_session(conn, params) do
    email = Map.get(params, "email") || generated_mint_email()
    display_name = Map.get(params, "display_name", "E2E Minted User")

    with true <- e2e_test_email?(email),
         {:ok, user} <-
           Accounts.register(%{
             "email" => email,
             "password" => @mint_password,
             "display_name" => display_name
           }),
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
  POST /api/test/book-writing  body: {"email": <email>, "book_id": <uuid>, "title": <optional>}

  Seeds a blog post authored by the given test user with a VISIBLE manual
  association to `book_id`, so the E2E suite can drive the spine bookmark-ribbon
  (#287) deterministically. The production path associates books via an async
  LLM worker on publish (`BlogAssociationHandler` → `PostBookAssociationWorker`),
  which is non-deterministic for a browser test — this helper writes the same
  end state directly via `Blog.associate_book/3` (visible, source `manual`).

  Scoped to `@thestacks.test` emails ONLY (like every other helper here) — a real
  account can never be in the reserved test TLD, so this can never fabricate
  writing for a real user even on a public preview with the flag on. Responds
  `201 {"ok": true, "post_id", "association_id"}` on success, a plain `404` for an
  out-of-scope email or unknown user, and `422 {"errors": ...}` when the post or
  association cannot be created.
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

  # Unique default address in the reserved E2E domain — mirrors uniqueEmail()
  # in e2e/tests/helpers.ts so minted users are recognisable in preview data.
  defp generated_mint_email do
    "e2e-mint-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}@thestacks.test"
  end

  # Same mint path as AuthController.login (Issue #179, Phase 2a): the
  # family_id is generated BEFORE minting so it is embedded as a claim, and the
  # token family row must persist or the token is revoked (fail closed) —
  # preserving the invariant that every live access token has a family.
  defp issue_session(conn, user) do
    fid = Ecto.UUID.generate()
    {:ok, token, claims} = Guardian.encode_and_sign(user, %{"family_id" => fid})

    family_attrs = %{
      family_id: fid,
      user_id: user.id,
      current_jti: claims["jti"],
      session_started_at: DateTime.from_unix!(claims["sst"])
    }

    case Accounts.open_token_family(family_attrs) do
      {:ok, _family} ->
        conn
        |> put_status(:created)
        |> json(%{
          email: user.email,
          token: token,
          user_id: user.id,
          display_name: user.display_name
        })

      {:error, reason} ->
        Logger.error("open_token_family failed on E2E session mint: #{inspect(reason)}")
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

  # Scope the endpoint to E2E/test-domain emails only. Case-insensitive to match
  # `Accounts.get_user_by_email/1`. Uses a strict domain-suffix match so
  # lookalikes such as `x@thestacks.test.evil.com` do NOT qualify.
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
