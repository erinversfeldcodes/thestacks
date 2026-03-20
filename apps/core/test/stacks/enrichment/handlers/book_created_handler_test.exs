defmodule Stacks.Enrichment.Handlers.BookCreatedHandlerTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  alias Stacks.Enrichment.Handlers.BookCreatedHandler
  alias Stacks.Workers.TriggerPriceScrapeJob

  describe "handle_event/1" do
    test "enqueues TriggerPriceScrapeJob for book.created with ISBN" do
      book_id = Ecto.UUID.generate()

      event = %{
        event_type: "book.created",
        aggregate_type: "book",
        aggregate_id: book_id,
        payload: %{"isbn" => "9780743273565", "title" => "The Great Gatsby"}
      }

      assert :ok = BookCreatedHandler.handle_event(event)

      assert_enqueued(
        worker: TriggerPriceScrapeJob,
        args: %{isbn: "9780743273565", book_id: book_id}
      )
    end

    test "skips enqueue when no ISBN in payload" do
      event = %{
        event_type: "book.created",
        aggregate_type: "book",
        aggregate_id: Ecto.UUID.generate(),
        payload: %{"title" => "Unknown Book"}
      }

      assert :ok = BookCreatedHandler.handle_event(event)
      refute_enqueued(worker: TriggerPriceScrapeJob)
    end

    test "handles atom-keyed payload" do
      book_id = Ecto.UUID.generate()

      event = %{
        event_type: "book.created",
        aggregate_type: "book",
        aggregate_id: book_id,
        payload: %{isbn: "9780743273565"}
      }

      assert :ok = BookCreatedHandler.handle_event(event)
      assert_enqueued(worker: TriggerPriceScrapeJob)
    end

    test "ignores unrelated events" do
      event = %{
        event_type: "user.registered",
        aggregate_type: "user",
        aggregate_id: Ecto.UUID.generate(),
        payload: %{}
      }

      assert :ok = BookCreatedHandler.handle_event(event)
      refute_enqueued(worker: TriggerPriceScrapeJob)
    end

    test "catch-all clause handles events without matching structure" do
      assert :ok = BookCreatedHandler.handle_event(%{event_type: "something.else"})
      refute_enqueued(worker: TriggerPriceScrapeJob)
    end
  end
end
