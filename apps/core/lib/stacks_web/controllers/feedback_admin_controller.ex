defmodule StacksWeb.FeedbackAdminController do
  @moduledoc """
      The owner's feedback queue.

      This is the ONLY way the message bodies leave the database, which is why
      it sits behind the `:admin` pipeline — MFA-verified session plus
      `AuditAdminCall`. Reading someone's feedback is an access to their
      personal data, and the audit row is what makes that accountable.
  """

  use CoreWeb, :controller

  alias Stacks.Feedback

  @doc """
      GET /api/admin/feedback — `?limit=` and `?offset=` page the queue.

      `total` is returned because this is the only interface that reads feedback and
      it reads one page at a time: without it, a full page and a truncated queue look
      identical, and the entries that fall off the end are the oldest.
  """
  def index(conn, params) do
    opts =
      [limit: int_param(params, "limit"), offset: int_param(params, "offset")]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    json(conn, %{
      feedback: Enum.map(Feedback.list_entries(opts), &entry_json/1),
      total: Feedback.count_entries()
    })
  end

  # An unparseable value falls back to the default rather than 400ing: this is an
  # operator surface reached by hand, and a typo should show the first page, not an
  # error. `list_entries/1` clamps whatever arrives.
  defp int_param(params, key) do
    case params[key] do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, ""} -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp entry_json(entry) do
    %{
      id: entry.id,
      body: entry.body,
      page_context: entry.page_context,
      sender_handle: sender_handle(entry.user),
      created_at: DateTime.to_iso8601(entry.created_at)
    }
  end

  # A handle, not an email: the owner needs to know who to write back to, and
  # the handle is enough to find them without putting an address in the list.
  defp sender_handle(%{handle: handle}), do: handle
  defp sender_handle(_), do: nil
end
