defmodule Core.Repo.Migrations.WritingAssistantSubstrateEncryptedAtRest do
  @moduledoc """
      The writing-assistant foundation: the item-0 chunk substrate, the
      imported-works + annotation tables, and the encrypted-at-rest posture.

      `op.embeddings` shipped in July as a plaintext `vector(1024)` + HNSW index.
      The research settled that a plaintext vector column is a
      near-complete copy of the corpus (vec2text recovers ~92% of short inputs),
      and a tsvector/GIN index is the corpus transcribed — so encrypting only the
      chunk text while vectors stay plaintext is "redacting the document but
      shipping its photocopy". The posture, strongest-first:

        * vectors AES-GCM (Cloak) encrypted, EXACT brute-force kNN in app memory
          (benchmarked on this stack: ~0.14ms/vector — 112ms at 10³ chunks, well
          inside a multi-second LLM turn; HNSW-on-quantized is the recorded
          fallback only when a real corpus crosses ~10⁴);
        * NO tsvector/trgm index over corpus text (vector-only retrieval);
        * chunk text + sensitive metadata (title, shelf) Cloak-encrypted, decrypt
          top-k only;
        * erasure crypto-shreds via CLOAK_KEY destruction/rotation, on top of the
          user-FK cascade and the `writing_assistant` consent purge.

      The table is EMPTY (no producer or retriever is built yet), so
      the plaintext→encrypted refactor migrates no data.

      Also lands §2.3 item-0 (chunk text, span provenance, a model stamp so a
      re-embed coexists, embedding_version), `op.prompt_templates` /
      `op.prompt_experiments` (§9, NON-personal platform config), and the §4a
      imported-works + per-work/per-chunk annotation tables (the author's OWN
      unpublished writing — the most sensitive text the platform holds, same GDPR
      standing as the corpus it annotates).

      GDPR: `op.imported_works` and `op.corpus_annotations` are PERSONAL,
      user-scoped, erased by the `user_id` FK cascade, purged on
      `writing_assistant` consent revocation, and crypto-shredded via the Cloak
      key for their encrypted columns. `op.prompt_templates` /
      `op.prompt_experiments` carry no user dimension.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # --- op.embeddings: plaintext vector -> Cloak-encrypted, + item-0 substrate ---
    execute("DROP INDEX IF EXISTS op.embeddings_embedding_hnsw_idx")
    execute("ALTER TABLE op.embeddings DROP COLUMN embedding")

    alter table(:embeddings, prefix: "op") do
      # ⛔ Cloak-encrypted (bytea): the serialized float32 vector, AES-GCM, so a
      # DB/backup/branch leak yields ciphertext, not a vec2text-recoverable copy.
      add :embedding, :binary, null: false
      # The source text and sensitive metadata, Cloak-encrypted; decrypt top-k only.
      add :chunk_text, :binary
      # title/shelf were plaintext text; re-added encrypted (sensitive metadata).
      remove :title
      remove :shelf
      add :title, :binary
      add :shelf, :binary
      # item-0 span provenance + model stamp + version (a re-embed coexists).
      add :chunk_index, :integer
      add :char_start, :integer
      add :char_end, :integer
      add :model, :text
      add :embedding_version, :integer
    end

    # --- §4a: the author's OWN imported writing (per-work metadata) ---
    create table(:imported_works, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, prefix: "op", on_delete: :delete_all),
        null: false

      add :title, :binary, null: false
      add :source_format, :text, null: false
      add :source_sha256, :text
      add :imported_at, :timestamptz, null: false

      timestamps(type: :timestamptz)
    end

    create index(:imported_works, [:user_id], prefix: "op")

    # --- §4a: first-class annotation, per-work OR per-chunk ---
    create table(:corpus_annotations, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, prefix: "op", on_delete: :delete_all),
        null: false

      add :work_id,
          references(:imported_works, type: :binary_id, prefix: "op", on_delete: :delete_all)

      add :embedding_id,
          references(:embeddings, type: :binary_id, prefix: "op", on_delete: :delete_all)

      add :tags, {:array, :text}, null: false, default: []
      add :exemplar_quality, :integer
      # ⛔ The redaction flag — enforced at the retrieval seam so a
      # redacted chunk is never retrievable. Lives beside the chunk, queryable.
      add :do_not_retrieve, :boolean, null: false, default: false
      # A free-text annotation note, Cloak-encrypted (sensitive).
      add :note, :binary

      timestamps(type: :timestamptz)
    end

    create index(:corpus_annotations, [:user_id], prefix: "op")
    create index(:corpus_annotations, [:work_id], prefix: "op")
    create index(:corpus_annotations, [:embedding_id], prefix: "op")

    # ⚖️ An annotation targets exactly one of a work or a chunk, never neither.
    create constraint(:corpus_annotations, :annotation_targets_one,
             check: "(work_id IS NOT NULL) <> (embedding_id IS NOT NULL)",
             prefix: "op"
           )

    # --- §9: metaprompting (NON-personal platform config) ---
    create table(:prompt_templates, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :role, :text, null: false
      add :version, :integer, null: false
      add :content, :text, null: false
      add :model_id, :text
      add :active, :boolean, null: false, default: false

      timestamps(type: :timestamptz, updated_at: false)
    end

    create unique_index(:prompt_templates, [:name, :version], prefix: "op")

    create constraint(:prompt_templates, :role_is_known,
             check: "role IN ('system', 'classification', 'summary')",
             prefix: "op"
           )

    create table(:prompt_experiments, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :template_id,
          references(:prompt_templates, type: :binary_id, prefix: "op", on_delete: :delete_all),
          null: false

      add :variant_name, :text, null: false
      add :traffic_split, :float, null: false
      add :started_at, :timestamptz, null: false
      add :ended_at, :timestamptz

      timestamps(type: :timestamptz, updated_at: false)
    end

    create index(:prompt_experiments, [:template_id], prefix: "op")
  end

  @breaking_ok "op.embeddings is empty — no producer or retriever exists yet — so the plaintext embedding/title/shelf columns this up/0 drops carry no data and have no N-1 reader (only the purge worker, which deletes by user_id and is type-agnostic); the retype breaks no live read, and down/0 restores the original vector(1024) + HNSW shape."

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    drop table(:prompt_experiments, prefix: "op")
    drop table(:prompt_templates, prefix: "op")
    drop table(:corpus_annotations, prefix: "op")
    drop table(:imported_works, prefix: "op")

    alter table(:embeddings, prefix: "op") do
      remove :embedding
      remove :chunk_text
      remove :title
      remove :shelf
      remove :chunk_index
      remove :char_start
      remove :char_end
      remove :model
      remove :embedding_version
      add :title, :text
      add :shelf, :text
    end

    execute("ALTER TABLE op.embeddings ADD COLUMN embedding vector(1024)")

    execute("""
    -- squawk-ignore require-concurrent-index-creation
    CREATE INDEX embeddings_embedding_hnsw_idx ON op.embeddings USING hnsw (embedding vector_cosine_ops)
    """)
  end
end
