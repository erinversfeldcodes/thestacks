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

  # The admin queue reads a page at a time. `@max_limit` exists so a hand-typed
  # `?limit=100000` cannot ask the only reader interface to load the whole table.
  @default_limit 100
  @max_limit 200

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
    |> validate_page_context()
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
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp(1, @max_limit, @default_limit)
    offset = opts |> Keyword.get(:offset, 0) |> clamp(0, nil, 0)

    Entry
    |> order_by([e], desc: e.created_at)
    |> limit(^limit)
    |> offset(^offset)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
      How many entries exist in total.

      The admin queue is the ONLY interface that can read feedback, and it reads a
      page at a time, so without this a reader cannot tell a full queue from a
      truncated one — and the end that falls off is the OLDEST, which for a beta
      channel is the feedback most likely to have gone unanswered.
  """
  @spec count_entries() :: non_neg_integer()
  def count_entries, do: Repo.aggregate(Entry, :count)

  # A non-integer falls back to the DEFAULT, not to the floor: this is reached from a
  # hand-typed admin query string, where `?limit=all` showing one entry would read as
  # an empty queue rather than as a rejected parameter.
  defp clamp(value, lo, hi, _default) when is_integer(value) do
    value = if hi, do: min(value, hi), else: value
    max(value, lo)
  end

  defp clamp(_value, _lo, _hi, default), do: default

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

  # `page_context` arrives as ordinary client input, so it is validated rather than
  # trusted. Only the "not a URL" half of the proto's old claim is enforceable, and
  # only loosely: a scheme, a query or a fragment all mean something other than a
  # short context label was sent.
  #
  # The stronger half — that it never names another reader — is NOT enforceable here.
  # A label for a static route ("/about", or the bare "wishlist" this field also
  # carries) is indistinguishable in shape from a concrete path naming a person
  # ("/u/somehandle"), and enumerating the valid set would copy the SPA's route table
  # across the boundary and drift from it. So the proto comment now describes the
  # field as untrusted rather than asserting a guarantee nothing keeps, and readers of
  # the admin queue should treat it as reader-supplied text.
  defp validate_page_context(changeset) do
    validate_change(changeset, :page_context, fn :page_context, value ->
      cond do
        value in [nil, ""] -> []
        String.contains?(value, "://") -> [page_context: "must not be a URL"]
        String.contains?(value, "?") -> [page_context: "must not carry a query string"]
        String.contains?(value, "#") -> [page_context: "must not carry a fragment"]
        true -> []
      end
    end)
  end
end
