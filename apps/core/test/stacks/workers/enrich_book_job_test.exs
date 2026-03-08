defmodule Stacks.Workers.EnrichBookJobTest do
  @moduledoc """
  Tests for Stacks.Workers.EnrichBookJob.

  The worker is currently a stub that logs and returns :ok. Tests verify that
  it executes without crashing and returns the expected value.
  """

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Workers.EnrichBookJob

  describe "perform/1" do
    test "returns :ok for a valid book_id" do
      book = insert(:book)

      assert :ok = perform_job(EnrichBookJob, %{"book_id" => book.id})
    end

    test "returns :ok for any book_id string (stub does not validate existence)" do
      assert :ok = perform_job(EnrichBookJob, %{"book_id" => Ecto.UUID.generate()})
    end
  end
end
