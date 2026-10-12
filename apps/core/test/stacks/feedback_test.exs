defmodule Stacks.FeedbackTest do
  @moduledoc """
      The feedback context, and the containment its whole design rests on: the
      body reaches the table and nowhere else — not the event payload, not a
      surviving row after erasure — and it comes back out in the export.
  """

  use Core.DataCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Events.EventLog
  alias Stacks.Feedback
  alias Stacks.GDPR.Deletion
  alias Stacks.GDPR.Export

  describe "submit/3" do
    test "records what the reader wrote, and where they were" do
      user = insert(:user)

      assert {:ok, entry} =
               Feedback.submit(
                 user.id,
                 "The spine widths look wrong on the wishlist.",
                 "wishlist"
               )

      assert entry.user_id == user.id
      assert entry.body == "The spine widths look wrong on the wishlist."
      assert entry.page_context == "wishlist"
      assert entry.created_at
    end

    test "page context is optional — a reader may just have something to say" do
      user = insert(:user)

      assert {:ok, entry} = Feedback.submit(user.id, "Thank you for building this.")
      assert entry.page_context == nil
    end

    test "an empty message is not feedback" do
      user = insert(:user)

      assert {:error, changeset} = Feedback.submit(user.id, "")
      assert %{body: _} = errors_on(changeset)
    end

    test "a message of nothing but whitespace is empty too" do
      user = insert(:user)

      assert {:error, changeset} = Feedback.submit(user.id, "   \n  ")
      assert %{body: _} = errors_on(changeset)
    end

    test "an oversize message is refused rather than truncated" do
      user = insert(:user)

      assert {:error, changeset} = Feedback.submit(user.id, String.duplicate("a", 5_001))
      assert %{body: _} = errors_on(changeset)
    end

    test "the longest acceptable message is accepted" do
      user = insert(:user)

      assert {:ok, _entry} = Feedback.submit(user.id, String.duplicate("a", 5_000))
    end

    test "an unbounded page context is refused — it is a label, not a payload" do
      user = insert(:user)

      assert {:error, changeset} =
               Feedback.submit(user.id, "Something broke.", String.duplicate("a", 201))

      assert %{page_context: _} = errors_on(changeset)
    end
  end

  describe "submit/3 event emission" do
    test "emits feedback.submitted carrying a count and a sender, never the words" do
      user = insert(:user)
      body = "The login door animation stutters on my phone."

      {:ok, entry} = Feedback.submit(user.id, body, "login")

      event = Repo.one!(from e in EventLog, where: e.aggregate_id == ^entry.id)

      assert event.event_type == "feedback.submitted"
      assert event.aggregate_type == "feedback"
      assert event.payload["user_id"] == user.id
      assert event.payload["character_count"] == String.length(body)

      refute Enum.any?(
               Map.values(event.payload),
               &(is_binary(&1) and String.contains?(&1, "door"))
             )
    end

    test "a refused submission emits nothing" do
      user = insert(:user)

      before =
        Repo.aggregate(from(e in EventLog, where: e.event_type == "feedback.submitted"), :count)

      {:error, _} = Feedback.submit(user.id, "")

      assert Repo.aggregate(
               from(e in EventLog, where: e.event_type == "feedback.submitted"),
               :count
             ) ==
               before
    end
  end

  describe "list_entries/1" do
    test "newest first — the owner reads the queue from the top" do
      user = insert(:user)

      {:ok, older} = Feedback.submit(user.id, "The first thing I noticed.")
      {:ok, newer} = Feedback.submit(user.id, "And then this.")

      # Both rows land inside the same microsecond-resolution instant often
      # enough that ordering must be forced to be tested at all.
      Repo.update_all(
        from(f in Stacks.Feedback.Entry, where: f.id == ^older.id),
        set: [created_at: DateTime.add(DateTime.utc_now(), -1, :hour)]
      )

      assert [first, second] = Feedback.list_entries()
      assert first.id == newer.id
      assert second.id == older.id
    end

    test "carries the sender, so the owner can see who wrote it" do
      user = insert(:user, handle: "mara")
      {:ok, _} = Feedback.submit(user.id, "A note from a reader.")

      assert [entry] = Feedback.list_entries()
      assert entry.user.handle == "mara"
    end

    test "respects a limit" do
      user = insert(:user)
      for n <- 1..3, do: Feedback.submit(user.id, "Report number #{n}.")

      assert length(Feedback.list_entries(limit: 2)) == 2
    end
  end

  describe "GDPR reachability" do
    test "erasure DELETES the body — it does not merely unname the author" do
      user = insert(:user)
      {:ok, _} = Feedback.submit(user.id, "A sentence only this reader wrote.", "library")

      assert {:ok, _} = Deletion.delete_user_data(user.id)

      # Asserting on the body, not on a row count: a count passes against a
      # SET NULL implementation that leaves the words behind.
      bodies = Repo.all(from f in Stacks.Feedback.Entry, select: f.body)
      refute "A sentence only this reader wrote." in bodies
    end

    test "erasure leaves another reader's feedback alone" do
      user = insert(:user)
      other = insert(:user)
      {:ok, _} = Feedback.submit(user.id, "Mine.")
      {:ok, kept} = Feedback.submit(other.id, "Not mine.")

      assert {:ok, _} = Deletion.delete_user_data(user.id)

      assert Repo.get(Stacks.Feedback.Entry, kept.id)
    end

    test "the erasure preview counts the rows it is about to delete" do
      user = insert(:user)
      {:ok, _} = Feedback.submit(user.id, "Something to count.")

      assert {:ok, %{feedback_entries: 1}} = Deletion.preview_user_data(user.id)
    end

    test "export carries the reader's own words back to them" do
      user = insert(:user)
      {:ok, _} = Feedback.submit(user.id, "What I told them about the bookcase.", "library")

      assert {:ok, export} = Export.export_user_data(user.id)

      assert [%{body: "What I told them about the bookcase.", page_context: "library"}] =
               export.feedback
    end

    test "export does not carry anyone else's feedback" do
      user = insert(:user)
      other = insert(:user)
      {:ok, _} = Feedback.submit(user.id, "Mine.")
      {:ok, _} = Feedback.submit(other.id, "Theirs.")

      assert {:ok, export} = Export.export_user_data(user.id)

      assert Enum.map(export.feedback, & &1.body) == ["Mine."]
    end
  end
end
