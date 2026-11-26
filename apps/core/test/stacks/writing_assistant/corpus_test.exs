defmodule Stacks.WritingAssistant.CorpusTest do
  use Core.DataCase, async: false

  import Stacks.Factory
  import Ecto.Query

  alias Core.Repo
  alias Stacks.WritingAssistant.{Corpus, CorpusAnnotation, Embedding, ImportedWork}

  @content "the raw bytes are never persisted; the mock extractor returns a fixed text"

  describe "import_document/4" do
    test "extracts, chunks, embeds, and stores encrypted chunks + a metadata row" do
      user = insert(:user)

      assert {:ok, %{work: work, chunks: n}} =
               Corpus.import_document(user.id, "My Manuscript", @content, "txt")

      assert n > 0
      assert %ImportedWork{} = Repo.get(ImportedWork, work.id)
      # title round-trips through EncryptedBinary; source_sha256 is a digest of
      # the bytes, which are themselves never stored.
      assert work.title == "My Manuscript"
      assert work.source_format == "txt"
      assert work.source_sha256 == Base.encode16(:crypto.hash(:sha256, @content), case: :lower)

      rows =
        Repo.all(
          from(e in Embedding,
            where: e.source_type == "imported_work" and e.source_id == ^work.id
          )
        )

      assert rows != []
      row = hd(rows)
      assert row.user_id == user.id
      assert row.model == "bge-m3"
      # chunk text + vector both decrypt on load.
      assert row.chunk_text =~ "summer's day"
      assert length(row.embedding) == 1024
    end

    test "rejects an unsupported format and writes nothing" do
      user = insert(:user)

      assert {:error, {:unsupported_format, "rtf"}} =
               Corpus.import_document(user.id, "T", "x", "rtf")

      assert Repo.aggregate(ImportedWork, :count) == 0
    end
  end

  describe "annotation" do
    test "annotate_work records tags, exemplar quality, and the do-not-retrieve flag" do
      user = insert(:user)
      {:ok, %{work: work}} = Corpus.import_document(user.id, "W", @content, "md")

      assert {:ok, %CorpusAnnotation{} = a} =
               Corpus.annotate_work(user.id, work.id, %{
                 tags: ["exemplar"],
                 exemplar_quality: 5,
                 do_not_retrieve: true,
                 note: "a private note"
               })

      assert a.work_id == work.id
      assert a.embedding_id == nil
      assert a.tags == ["exemplar"]
      assert a.exemplar_quality == 5
      assert a.do_not_retrieve == true
      assert a.note == "a private note"
    end

    test "annotate_chunk targets an embedding, satisfying the work/chunk XOR" do
      user = insert(:user)
      {:ok, %{work: work}} = Corpus.import_document(user.id, "W", @content, "txt")
      [chunk | _] = Repo.all(from(e in Embedding, where: e.source_id == ^work.id))

      assert {:ok, a} = Corpus.annotate_chunk(user.id, chunk.id, %{do_not_retrieve: true})
      assert a.embedding_id == chunk.id
      assert a.work_id == nil
    end
  end
end
