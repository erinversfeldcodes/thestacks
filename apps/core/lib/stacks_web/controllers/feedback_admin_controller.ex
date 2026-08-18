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

  @doc "GET /api/admin/feedback"
  def index(conn, _params) do
    json(conn, %{feedback: Enum.map(Feedback.list_entries(), &entry_json/1)})
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
