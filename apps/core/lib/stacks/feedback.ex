defmodule Stacks.Feedback do
  @moduledoc """
      The beta feedback channel: a signed-in reader writes to the person who
      built this, and the owner reads it in admin.

      The whole design is containment of one column. `body` is free text a
      reader wrote and may name people who never agreed to be named, so it
      lives in exactly one place: `op.feedback_entries`, reachable only through
      the MFA-gated, audited admin list. It is never put in the event payload
      (`feedback.submitted` carries a sender id and a character COUNT — a count
      answers "did anyone actually write anything" without quoting them), and
      the table is `skip_dbt` so no copy reaches the warehouse, which has no
      erasure path.

      Erasure DELETES the row rather than nulling `user_id`: nulling would
      leave the reader's own words in the table after they asked to be
      forgotten. `Stacks.GDPR.Deletion` does that explicitly, belt to the FK
      cascade's braces, so the guarantee does not depend on cascade timing.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Core.Repo
  alias Stacks.Events
  alias Stacks.Feedback.Entry

  @body_max 5_000
  @page_context_max 200

  @doc """
      Records one piece of feedback from a signed-in reader.

      `page_context` is a short label for where they were — a hint for
      reproducing the problem, not a URL, and it is length-capped so an
      unbounded client string cannot be smuggled in behind it.

      Returns `{:ok, entry}`, or `{:error, changeset}` for an empty or
      oversize body.
  """
  @spec submit(binary(), String.t(), String.t() | nil) ::
          {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def submit(user_id, body, page_context \\ nil) do
    %Entry{}
    |> cast(%{user_id: user_id, body: body, page_context: page_context}, [
      :user_id,
      :body,
      :page_context
    ])
    |> update_change(:body, &String.trim/1)
    # The column has a NOW() default, but a default only fills the row — the
    # struct handed back from the insert would carry a nil, and the caller
    # would serialise it.
    |> put_change(:created_at, DateTime.utc_now())
    |> validate_required([:user_id, :body])
    |> validate_length(:body, min: 1, max: @body_max)
    |> validate_length(:page_context, max: @page_context_max)
    |> foreign_key_constraint(:user_id)
    |> Repo.insert()
    |> emit_submitted()
  end

  @doc """
      Every piece of feedback, newest first — the owner's queue.

      `opts` may carry `:limit` (default 100). Preloads the sender so the admin
      list can say who wrote it.
  """
  @spec list_entries(keyword()) :: [Entry.t()]
  def list_entries(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Entry
    |> order_by([e], desc: e.created_at)
    |> limit(^limit)
    |> preload(:user)
    |> Repo.all()
  end

  # `user_id` is here so the erasure sweep can find this row by payload — the
  # same reason the blog events carry it. `character_count` is the only thing
  # said about what was written.
  defp emit_submitted({:ok, entry} = result) do
    Events.emit_safe(%{
      event_type: "feedback.submitted",
      aggregate_type: "feedback",
      aggregate_id: entry.id,
      payload: %{user_id: entry.user_id, character_count: String.length(entry.body)}
    })

    result
  end

  defp emit_submitted({:error, _changeset} = result), do: result
end
