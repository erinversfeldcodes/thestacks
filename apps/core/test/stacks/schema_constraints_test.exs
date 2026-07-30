defmodule Stacks.SchemaConstraintsTest do
  @moduledoc """
  Issue #335 — the four invariants that moved from code-that-remembers into the
  schema.

  Every test here writes AROUND the application: raw `Repo.insert_all/3` and raw
  SQL, never a changeset. That is deliberate and it is the whole point. Each of
  these rules already had an application-level guard, and each guard already
  worked; what none of them could do was constrain a writer that does not call
  them — a seed script, a `psql` session, a future bulk importer, a test factory.
  Proving the rule through `Books.book_edition_changeset/2` would prove the
  changeset, not the constraint, and would stay green if the constraint were
  dropped tomorrow.

  Where a `describe` block names a constraint, deleting that constraint from its
  migration turns the block red — that is the mutation probe each one is written
  to satisfy.
  """
  use Core.DataCase, async: false

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts.AuthTokenFamily
  alias Stacks.Shelving.Placement

  # A raw op.book_editions row. `overrides` is merged last so a test can omit a
  # column (proving NOT NULL) or supply a bad value (proving a CHECK).
  defp raw_edition(book_id, overrides) do
    now = DateTime.utc_now()

    row =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          book_id: Ecto.UUID.dump!(book_id),
          isbn: valid_isbn(),
          is_primary: false,
          verification_source: "open_library",
          created_at: now,
          updated_at: now
        },
        overrides
      )

    Repo.insert_all("book_editions", [row], prefix: "op")
  end

  # A 13-digit ISBN with a correct EAN-13 check digit, from a block no fixture
  # hard-codes. Mirrors `Stacks.Factory.next_isbn/0`'s reasoning.
  defp valid_isbn do
    body = "97819" <> String.pad_leading(to_string(System.unique_integer([:positive])), 7, "0")
    body <> check_digit(body)
  end

  defp check_digit(body) do
    sum =
      body
      |> String.graphemes()
      |> Enum.map(&String.to_integer/1)
      |> Enum.with_index()
      |> Enum.reduce(0, fn {d, i}, acc -> acc + d * if(rem(i, 2) == 0, do: 1, else: 3) end)

    Integer.to_string(rem(10 - rem(sum, 10), 10))
  end

  # ---------------------------------------------------------------------------
  # D1 — book_editions.verification_source
  # ---------------------------------------------------------------------------

  describe "op.book_editions.verification_source NOT NULL (20260730200000)" do
    test "an out-of-band insert that omits the provenance is rejected" do
      book = insert(:book)

      error =
        assert_raise Postgrex.Error, fn ->
          raw_edition(book.id, %{verification_source: nil})
        end

      assert error.postgres.code == :not_null_violation
      assert error.postgres.column == "verification_source"
    end

    test "every edition the ordinary write path creates carries a provenance" do
      book = insert(:book)
      edition = hd(Repo.preload(book, :editions).editions)

      assert edition.verification_source in Stacks.Books.verification_sources()
    end
  end

  describe "op.book_editions verification_source CHECK (20260730200000)" do
    test "an out-of-band insert cannot invent a fourth provenance" do
      book = insert(:book)

      error =
        assert_raise Postgrex.Error, fn ->
          raw_edition(book.id, %{verification_source: "vibes"})
        end

      assert error.postgres.code == :check_violation
      assert error.postgres.constraint == "book_editions_verification_source_check"
    end

    test "each of the three declared provenances is accepted" do
      for source <- Stacks.Books.verification_sources() do
        book = insert(:editionless_book)
        assert {1, _} = raw_edition(book.id, %{verification_source: source})
      end
    end
  end

  # ---------------------------------------------------------------------------
  # D4 — the ISBN checksum CHECK
  # ---------------------------------------------------------------------------

  describe "op.book_editions ISBN checksum CHECK (20260730200300)" do
    test "an out-of-band insert with a wrong check digit is rejected" do
      book = insert(:book)
      # 9780306406158 is the textbook example of a near-miss: correct body,
      # check digit off by one (the real one is 7).
      error =
        assert_raise Postgrex.Error, fn ->
          raw_edition(book.id, %{isbn: "9780306406158"})
        end

      assert error.postgres.code == :check_violation
      assert error.postgres.constraint == "book_editions_isbn_ean13_checksum"
    end

    test "an out-of-band insert of a non-ISBN string is rejected" do
      book = insert(:book)

      error =
        assert_raise Postgrex.Error, fn ->
          raw_edition(book.id, %{isbn: "not-an-isbn"})
        end

      assert error.postgres.constraint == "book_editions_isbn_ean13_checksum"
    end

    test "an ISBN-10, which the write path always converts, is rejected in its 10-digit form" do
      book = insert(:book)

      # 0306406152 is the same book's valid ISBN-10. The changeset normalises it
      # to 9780306406157 before storage, so a stored 10-digit value would itself
      # be a defect — the constraint says so.
      error =
        assert_raise Postgrex.Error, fn ->
          raw_edition(book.id, %{isbn: "0306406152"})
        end

      assert error.postgres.constraint == "book_editions_isbn_ean13_checksum"
    end

    test "a correct ISBN-13 is accepted" do
      book = insert(:editionless_book)
      assert {1, _} = raw_edition(book.id, %{isbn: "9780306406157"})
    end
  end

  # ---------------------------------------------------------------------------
  # D4 — case-insensitive email uniqueness
  # ---------------------------------------------------------------------------

  describe "op.users lower(email) unique index (20260730200500)" do
    test "an out-of-band insert cannot add an address that differs only in case" do
      user = insert(:user, email: "casefold@example.test")

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.insert_all(
            "users",
            [
              %{
                id: Ecto.UUID.generate(),
                email: "CaseFold@Example.TEST",
                password_hash: user.password_hash,
                handle: "casefold_probe",
                role: "user",
                created_at: DateTime.utc_now(),
                updated_at: DateTime.utc_now()
              }
            ],
            prefix: "op"
          )
        end

      assert error.postgres.code == :unique_violation
      assert error.postgres.constraint == "users_lower_email_index"
    end

    test "registration downcases the address it stores" do
      {:ok, user} =
        Stacks.Accounts.register(%{
          email: "MiXeD.Case@Example.TEST",
          password: "correct horse battery",
          display_name: "Mixed"
        })

      assert user.email == "mixed.case@example.test"

      # …and is therefore reachable by the login lookup, which downcases its
      # argument. Before #335 D4 this account existed and could never log in.
      assert Stacks.Accounts.get_user_by_email("mixed.case@example.test").id == user.id
    end

    test "a second registration differing only in case is a changeset error, not a 500" do
      # A CONFIRMED account: `register/1` reaps an abandoned (unconfirmed) signup
      # on the same address by design, so an unconfirmed first user would be
      # erased and the second registration would legitimately succeed.
      insert(:user, email: "dup@example.test")

      assert {:error, changeset} =
               Stacks.Accounts.register(%{
                 email: "DUP@Example.TEST",
                 password: "correct horse battery",
                 display_name: "Dup"
               })

      assert "has already been taken" in errors_on(changeset).email
    end
  end

  # ---------------------------------------------------------------------------
  # D3 — the two owner FKs the deletion path used to compensate for
  # ---------------------------------------------------------------------------

  describe "op.auth_token_families.user_id FK (20260730200200)" do
    test "a family naming no user is rejected" do
      error =
        assert_raise Ecto.ConstraintError, fn ->
          Repo.insert!(%AuthTokenFamily{
            family_id: Ecto.UUID.generate(),
            user_id: Ecto.UUID.generate(),
            current_jti: "orphan",
            session_started_at: DateTime.utc_now()
          })
        end

      assert error.constraint == "auth_token_families_user_id_fkey"
      assert error.type == :foreign_key
    end

    test "deleting a user takes their families with it — no application step involved" do
      user = insert(:user)

      Repo.insert!(%AuthTokenFamily{
        family_id: Ecto.UUID.generate(),
        user_id: user.id,
        current_jti: "live",
        session_started_at: DateTime.utc_now()
      })

      assert family_count(user.id) == 1

      # A bare delete: no Ecto.Multi, no GDPR module, nothing that remembers.
      Repo.delete!(user)

      assert family_count(user.id) == 0
    end
  end

  describe "op.guardian_tokens owner FK (20260730200200)" do
    test "a token whose sub names no user is rejected" do
      error =
        assert_raise Postgrex.Error, fn ->
          insert_raw_token(Ecto.UUID.generate())
        end

      assert error.postgres.code == :foreign_key_violation
      assert error.postgres.constraint == "guardian_tokens_user_id_fkey"
    end

    test "deleting a user takes their tokens with it — no application step involved" do
      user = insert(:user)
      insert_raw_token(to_string(user.id))

      assert guardian_token_count(user.id) == 1

      Repo.delete!(user)

      assert guardian_token_count(user.id) == 0
    end

    test "a token with no sub names no user and is left alone" do
      {1, _} = insert_raw_token(nil)

      assert Repo.aggregate(
               from(t in "guardian_tokens", prefix: "op", where: is_nil(t.sub)),
               :count,
               :jti
             ) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # D2 — placements.book_edition_id
  # ---------------------------------------------------------------------------

  describe "op.bookshelf_placements.book_edition_id FK (20260730193135)" do
    test "placing a book points the placement at the work's primary edition" do
      user = insert(:user)
      book = insert(:book)
      primary = hd(Repo.preload(book, :editions).editions)

      assert {:ok, placement} = Stacks.Shelving.place_book(user.id, book.id, "library")
      assert placement.book_edition_id == primary.id
    end

    test "a work with no edition still places, with no edition reference" do
      user = insert(:user)
      book = insert(:editionless_book)

      assert {:ok, placement} = Stacks.Shelving.place_book(user.id, book.id, "library")
      assert placement.book_edition_id == nil
    end

    test "a placement cannot reference an edition that does not exist" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user)

      error =
        assert_raise Ecto.ConstraintError, fn ->
          insert(:placement, bookshelf: bookshelf, book_edition_id: Ecto.UUID.generate())
        end

      assert error.constraint == "bookshelf_placements_book_edition_id_fkey"
      assert error.type == :foreign_key
    end

    test "deleting an edition releases the placement instead of deleting it" do
      user = insert(:user)
      book = insert(:book)
      edition = hd(Repo.preload(book, :editions).editions)
      {:ok, placement} = Stacks.Shelving.place_book(user.id, book.id, "library")

      Repo.delete!(edition)

      reloaded = Repo.get!(Placement, placement.id)
      assert reloaded.book_edition_id == nil, "the reader's shelf must survive an edition delete"
    end

    test "the same book on two bookshelves keeps both placements and both editions" do
      # #333 made this a legal state. `book_edition_id` must not narrow it.
      user = insert(:user)
      book = insert(:book)
      edition = hd(Repo.preload(book, :editions).editions)

      assert {:ok, library} = Stacks.Shelving.place_book(user.id, book.id, "library")
      assert {:ok, wishlist} = Stacks.Shelving.place_book(user.id, book.id, "wishlist")

      assert library.id != wishlist.id
      assert library.book_edition_id == edition.id
      assert wishlist.book_edition_id == edition.id
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp family_count(user_id) do
    Repo.aggregate(from(f in AuthTokenFamily, where: f.user_id == ^user_id), :count, :family_id)
  end

  defp guardian_token_count(user_id) do
    Repo.aggregate(
      from(t in "guardian_tokens", prefix: "op", where: t.sub == ^to_string(user_id)),
      :count,
      :jti
    )
  end

  # Writes an op.guardian_tokens row the way guardian_db does — schemalessly,
  # since the project owns no Ecto schema for that table.
  defp insert_raw_token(sub) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert_all(
      "guardian_tokens",
      [
        %{
          jti: "jti-#{System.unique_integer([:positive])}",
          aud: "stacks",
          typ: "access",
          sub: sub,
          exp: System.system_time(:second) + 8 * 60 * 60,
          inserted_at: now,
          updated_at: now
        }
      ],
      prefix: "op"
    )
  end
end
