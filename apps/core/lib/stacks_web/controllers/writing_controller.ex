defmodule StacksWeb.WritingController do
  @moduledoc """
      The consent-gated path for the author's own writing corpus: importing an
      unpublished document and annotating it. The work is
      `Stacks.WritingAssistant.Corpus`; this controller is the HTTP boundary.

      The whole controller is gated on the `writing_assistant` consent, so an
      import or annotation cannot land before the author has opted in — and the
      uploaded bytes are passed straight through to extraction, never persisted.
  """

  use CoreWeb, :controller

  plug StacksWeb.Plugs.ConsentCheck, feature: "writing_assistant"

  alias Stacks.Accounts.Guardian
  alias Stacks.WritingAssistant.Corpus

  def import(conn, %{"title" => title, "format" => format, "content" => content_b64}) do
    user = Guardian.Plug.current_resource(conn)

    case Base.decode64(content_b64) do
      {:ok, content} ->
        respond_import(conn, Corpus.import_document(user.id, title, content, format))

      :error ->
        conn |> put_status(400) |> json(%{error: "content must be base64-encoded"})
    end
  end

  def annotate_work(conn, %{"work_id" => work_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    {:ok, annotation} = Corpus.annotate_work(user.id, work_id, annotation_attrs(params))
    conn |> put_status(201) |> json(%{annotation_id: annotation.id})
  end

  def annotate_chunk(conn, %{"embedding_id" => embedding_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    {:ok, annotation} = Corpus.annotate_chunk(user.id, embedding_id, annotation_attrs(params))
    conn |> put_status(201) |> json(%{annotation_id: annotation.id})
  end

  defp respond_import(conn, {:ok, %{work: work, chunks: chunks}}),
    do: conn |> put_status(201) |> json(%{work_id: work.id, chunks: chunks})

  defp respond_import(conn, {:error, {:unsupported_format, format}}),
    do: conn |> put_status(422) |> json(%{error: "unsupported_format", format: format})

  defp respond_import(conn, {:error, :no_text_extracted}),
    do: conn |> put_status(422) |> json(%{error: "no_text_extracted"})

  defp respond_import(conn, {:error, _reason}),
    do: conn |> put_status(422) |> json(%{error: "import_failed"})

  defp annotation_attrs(params) do
    %{
      tags: Map.get(params, "tags", []),
      exemplar_quality: Map.get(params, "exemplar_quality"),
      do_not_retrieve: Map.get(params, "do_not_retrieve", false),
      note: Map.get(params, "note")
    }
  end
end
