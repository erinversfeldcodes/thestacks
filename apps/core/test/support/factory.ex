defmodule Stacks.Factory do
  @moduledoc """
  ExMachina factory for test data. Use `build/2` for in-memory structs
  and `insert/2` for persisted records.
  """

  use ExMachina.Ecto, repo: Core.Repo

  alias Stacks.Accounts.User
  alias Stacks.Books.{Author, Book}
  alias Stacks.Shelving.{Bookshelf, Placement, PlacementHistory}

  def user_factory do
    %User{
      email: sequence(:email, &"user#{&1}@example.com"),
      password_hash: Argon2.hash_pwd_salt("password123"),
      display_name: sequence(:display_name, &"User #{&1}"),
      role: "user",
      profile_visibility: "owner",
      age_verified: false,
      consent_analytics: false
    }
  end

  def owner_user_factory do
    struct!(user_factory(), role: "owner")
  end

  def author_factory do
    %Author{
      name: sequence(:author_name, &"Author #{&1}"),
      bio: "A talented writer."
    }
  end

  def book_factory do
    %Book{
      isbn: sequence(:isbn, &"978074327#{String.pad_leading(to_string(&1), 4, "0")}"),
      title: sequence(:title, &"Book Title #{&1}"),
      description: "A great book.",
      page_count: 300,
      publisher: "Test Publisher",
      publication_year: 2020,
      language: "en",
      subjects: ["fiction"],
      bisac_codes: ["FIC000000"],
      visibility_tier: "public"
    }
  end

  def book_with_author_factory do
    %{book_factory() | author: build(:author)}
  end

  def bookshelf_factory do
    %Bookshelf{
      name: "library",
      visibility: "owner",
      user: build(:user)
    }
  end

  def placement_factory do
    %Placement{
      position: 1,
      placed_at: DateTime.utc_now(),
      formats: [],
      visibility: "owner",
      book: build(:book),
      bookshelf: build(:bookshelf)
    }
  end

  def placement_history_factory do
    %PlacementHistory{
      book_id: Ecto.UUID.generate(),
      from_bookshelf: Ecto.UUID.generate(),
      to_bookshelf: Ecto.UUID.generate(),
      moved_at: DateTime.utc_now()
    }
  end
end
