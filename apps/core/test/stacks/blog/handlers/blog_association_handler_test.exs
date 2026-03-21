defmodule Stacks.Blog.Handlers.BlogAssociationHandlerTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  alias Stacks.Blog.Handlers.BlogAssociationHandler
  alias Stacks.Workers.PostBookAssociationWorker

  describe "handle_event/1" do
    test "enqueues PostBookAssociationWorker on blog.post_published" do
      post_id = Ecto.UUID.generate()

      assert :ok =
               BlogAssociationHandler.handle_event(%{
                 event_type: "blog.post_published",
                 aggregate_id: post_id,
                 payload: %{}
               })

      assert_enqueued(worker: PostBookAssociationWorker, args: %{post_id: post_id})
    end

    test "ignores unrelated events" do
      assert :ok =
               BlogAssociationHandler.handle_event(%{
                 event_type: "user.registered",
                 aggregate_id: Ecto.UUID.generate(),
                 payload: %{}
               })

      refute_enqueued(worker: PostBookAssociationWorker)
    end
  end
end
