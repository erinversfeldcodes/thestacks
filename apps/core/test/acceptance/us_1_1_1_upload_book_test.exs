defmodule Stacks.Acceptance.UploadBookTest do
  @moduledoc """
  Acceptance test for user story US-1.1.1: Upload → Identify → Place on shelf.
  Uses mocked vision client (Stacks.AI.MockClient) which is configured in test.exs.
  Oban is in :manual mode so jobs are enqueued but not executed inline.
  """

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Books
  alias Stacks.Shelving
  alias Stacks.Shelving.Bookshelf
  alias Stacks.Shelving.Placement
  alias Stacks.Workers.IdentifyBookJob

  describe "US-1.1.1 upload → identify → place on shelf" do
    test "happy path: image upload enqueues IdentifyBookJob and book can be placed on shelf" do
      {:ok, user} =
        Accounts.register(%{"email" => "reader@example.com", "password" => "password123"})

      # Pre-create the book that would be identified
      {:ok, book} = Books.create(%{"isbn" => "9780743273565", "title" => "The Great Gatsby"})

      # Step 1: upload image — enqueues job (manual mode, not executed)
      image_id = Ecto.UUID.generate()
      assert {:ok, _job} = Books.upload_and_identify(user.id, image_id)

      assert_enqueued(
        worker: IdentifyBookJob,
        args: %{"user_id" => user.id, "image_id" => image_id}
      )

      # Step 2: Place the pre-existing book on a shelf
      shelf =
        %Bookshelf{}
        |> Bookshelf.changeset(%{user_id: user.id, name: "library"})
        |> Repo.insert!()

      {:ok, placement} =
        Repo.insert(
          Placement.changeset(%Placement{}, %{
            book_id: book.id,
            bookshelf_id: shelf.id
          })
        )

      # Step 3: Verify book is on shelf
      placements = Shelving.get_shelf_books(user.id, "library")
      ids = Enum.map(placements, & &1.id)
      assert placement.id in ids
    end

    test "error path: upload with no existing book still enqueues job for async processing" do
      {:ok, user} =
        Accounts.register(%{"email" => "reader2@example.com", "password" => "password123"})

      image_id = Ecto.UUID.generate()

      # upload_and_identify only enqueues — does not validate image existence
      assert {:ok, _job} = Books.upload_and_identify(user.id, image_id)

      assert_enqueued(
        worker: IdentifyBookJob,
        args: %{"user_id" => user.id, "image_id" => image_id}
      )
    end
  end
end
