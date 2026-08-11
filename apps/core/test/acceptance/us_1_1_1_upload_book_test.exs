defmodule Stacks.Acceptance.UploadBookTest do
  @moduledoc """
  Acceptance test for user story US-1.1.1: Upload → Identify → Place on bookshelf.
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
  alias Stacks.Uploads
  alias Stacks.Workers.IdentifyBookJob

  describe "US-1.1.1 upload → identify → place on bookshelf" do
    test "happy path: image upload enqueues IdentifyBookJob and book can be placed on bookshelf" do
      {:ok, user} =
        Accounts.register(%{"email" => "reader@example.com", "password" => "password123"})

      {:ok, book} = Books.create(%{"isbn" => "9780743273565", "title" => "The Great Gatsby"})

      image_id = Ecto.UUID.generate()
      image_b64 = Base.encode64("fake image bytes")
      assert {:ok, _job} = Uploads.upload_and_identify(user.id, image_id, image_b64)

      assert_enqueued(
        worker: IdentifyBookJob,
        args: %{"user_id" => user.id, "image_id" => image_id}
      )

      {:ok, placement} = Shelving.place_book(user.id, book.id, "library")

      placements = Shelving.get_bookshelf_books(user.id, "library")
      ids = Enum.map(placements, & &1.id)
      assert placement.id in ids
    end

    test "error path: upload with no existing book still enqueues job for async processing" do
      {:ok, user} =
        Accounts.register(%{"email" => "reader2@example.com", "password" => "password123"})

      image_id = Ecto.UUID.generate()
      image_b64 = Base.encode64("fake image bytes")

      assert {:ok, _job} = Uploads.upload_and_identify(user.id, image_id, image_b64)

      assert_enqueued(
        worker: IdentifyBookJob,
        args: %{"user_id" => user.id, "image_id" => image_id}
      )
    end
  end
end
