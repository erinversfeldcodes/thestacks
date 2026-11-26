defmodule Stacks.WritingAssistant.RetrievalTest do
  @moduledoc """
      The retrieval seam's three guarantees, each probeable:

        * ranking — the nearest vector comes first and its text is decrypted;
        * user scope — another user's corpus is unreachable (drop the user_id
          filter and the cross-user assertion reds);
        * do-not-retrieve — a chunk-level or work-level redaction is excluded
          (drop the redaction filter and the redaction assertions red);
        * no leak — a retrieval logs nothing containing the decrypted chunk text;
        * version — only same-version vectors are scored.
  """
  use Core.DataCase, async: false

  import ExUnit.CaptureLog
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.WritingAssistant.{CorpusAnnotation, Embedding, ImportedWork, Retrieval}

  @version 1

  # A unit vector on axis `i` of 1024-space: cosine with the same axis is 1.0,
  # with any other axis 0.0 — so similarity is exactly controllable.
  defp axis(i), do: for(j <- 0..1023, do: if(j == i, do: 1.0, else: 0.0))

  defp chunk(user_id, axis_index, text, attrs \\ %{}) do
    defaults = %{
      user_id: user_id,
      source_type: "imported_work",
      source_id: Ecto.UUID.generate(),
      embedding: axis(axis_index),
      chunk_text: text,
      chunk_index: 0,
      model: "bge-m3",
      embedding_version: @version
    }

    Repo.insert!(struct(Embedding, Map.merge(defaults, attrs)))
  end

  test "ranks the nearest chunk first and decrypts its text" do
    user = insert(:user)
    chunk(user.id, 5, "the summer manuscript")
    chunk(user.id, 900, "an unrelated fragment")

    [top | _] = Retrieval.retrieve(user.id, axis(5), embedding_version: @version)

    assert top.chunk_text == "the summer manuscript"
    assert_in_delta top.score, 1.0, 1.0e-9
  end

  test "is user-scoped — another user's chunks are never returned" do
    me = insert(:user)
    other = insert(:user)
    chunk(me.id, 5, "my private draft")
    chunk(other.id, 5, "their private draft")

    texts =
      me.id
      |> Retrieval.retrieve(axis(5), embedding_version: @version)
      |> Enum.map(& &1.chunk_text)

    assert "my private draft" in texts
    refute "their private draft" in texts
  end

  test "excludes a chunk-level do_not_retrieve redaction" do
    user = insert(:user)
    redacted = chunk(user.id, 5, "redacted chunk")
    chunk(user.id, 5, "kept chunk")

    Repo.insert!(%CorpusAnnotation{
      user_id: user.id,
      embedding_id: redacted.id,
      do_not_retrieve: true
    })

    texts =
      user.id
      |> Retrieval.retrieve(axis(5), embedding_version: @version)
      |> Enum.map(& &1.chunk_text)

    refute "redacted chunk" in texts
    assert "kept chunk" in texts
  end

  test "excludes every chunk of a work-level do_not_retrieve redaction" do
    user = insert(:user)

    work =
      Repo.insert!(%ImportedWork{
        user_id: user.id,
        title: "Manuscript",
        source_format: "txt",
        imported_at: DateTime.utc_now()
      })

    chunk(user.id, 5, "work chunk 0", %{source_id: work.id, chunk_index: 0})
    chunk(user.id, 6, "work chunk 1", %{source_id: work.id, chunk_index: 1})
    chunk(user.id, 5, "a different work's chunk")

    Repo.insert!(%CorpusAnnotation{
      user_id: user.id,
      work_id: work.id,
      do_not_retrieve: true
    })

    texts =
      user.id
      |> Retrieval.retrieve(axis(5), embedding_version: @version, k: 10)
      |> Enum.map(& &1.chunk_text)

    refute "work chunk 0" in texts
    refute "work chunk 1" in texts
    assert "a different work's chunk" in texts
  end

  test "no decrypted chunk text appears in the logs" do
    user = insert(:user)
    secret = "a very secret sentence from the manuscript"
    chunk(user.id, 5, secret)

    log =
      capture_log(fn ->
        Retrieval.retrieve(user.id, axis(5), embedding_version: @version)
      end)

    refute log =~ secret
  end

  test "the exact-version filter ignores other-version vectors" do
    user = insert(:user)
    chunk(user.id, 5, "version one chunk")
    chunk(user.id, 5, "version two chunk", %{embedding_version: 2})

    texts =
      user.id
      |> Retrieval.retrieve(axis(5), embedding_version: 1)
      |> Enum.map(& &1.chunk_text)

    assert "version one chunk" in texts
    refute "version two chunk" in texts
  end
end
