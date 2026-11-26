defmodule Core.Repo.Migrations.RecordWhatTheModelSaid do
  @moduledoc """
      A bounded record of every LLM call, including the text when it could not
      be read.

      ⛔ WITHOUT THIS, A PARSE FAILURE IS A LOG LINE AND A SHRUG. MEASURED
      against the live model: 3 of 3 association responses came back fenced,
      `Jason.decode/1` failed on all three, and the only trace was
      "failed to parse LLM response for post …" — with the text that would have
      explained it discarded. The eval harness this wave is building scores
      model OUTPUTS, and there were none to score.

      ⚖️ **PERSONAL DATA, AND TREATED AS SUCH.** `raw_response` is model output
      about a reader's post, so the row is reachable by erasure through
      `blog_posts` → `users`, both `on_delete: :delete_all`. The prompt is
      stored as a **hash**, never as text: the prompt embeds the post body, and
      keeping a second copy of a reader's writing in a diagnostic table is how a
      log becomes an undeclared archive of personal data.

      ⚠️ **TWO BOUNDS, FOR TWO DIFFERENT REASONS.** 8 KB on `raw_response`
      because a runaway model must not be able to write unbounded rows; 30 days
      because this is a debugging and eval-capture record, not a permanent one,
      and an unbounded retention would quietly become one.
  """
  use Ecto.Migration

  def up do
    # ⚠️ The project's convention, and `scripts/security-squawk.sh` enforces it:
    # a migration that can wait on a lock says how long it will wait. Without
    # these, a DDL statement blocks behind any open transaction indefinitely and
    # every reader queues behind it — which is worse than failing and being
    # retried.
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    create table(:llm_call_log, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      # ⛔ CASCADES, so erasure reaches it. A `nilify_all` here would keep the
      # model's text about a reader's post after the reader was deleted —
      # removing the reference while leaving the content, which is the exact
      # defect that survived seven reviews and a green schema-guard in the GDPR
      # epic.
      add :post_id,
          references(:blog_posts, type: :binary_id, prefix: "op", on_delete: :delete_all),
          null: false

      add :model, :text, null: false

      # ⚠️ A HASH, NOT THE PROMPT. The prompt contains the post body.
      add :prompt_sha256, :text, null: false

      add :outcome, :text, null: false
      add :prompt_tokens, :integer
      add :completion_tokens, :integer
      add :latency_ms, :integer

      # ⚖️ Nullable: a transport error has no response to record, and writing
      # an empty string for it would make "the model said nothing" and "the
      # model was never reached" indistinguishable.
      add :raw_response, :text

      # ⚠️ `:timestamptz`, not `timestamps(type: :utc_datetime_usec)`. That
      # spelling produces `timestamp WITHOUT time zone`, which this project
      # converted every column away from precisely so a row's meaning does not
      # depend on every reader agreeing which zone wrote it. The timestamp gate
      # catches it, and caught this one.
      add :created_at, :timestamptz, null: false, default: fragment("now()")
      add :updated_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:llm_call_log, [:post_id], prefix: "op")
    # ⚠️ `created_at`, not `inserted_at`: this project renames it in
    # `migration_timestamps`, so the usual spelling builds an index on a column
    # that does not exist.
    create index(:llm_call_log, [:created_at], prefix: "op")
    create index(:llm_call_log, [:outcome], prefix: "op")

    # ⛔ THE BOUND IS A CONSTRAINT, NOT A CONVENTION. Enforcing 8 KB in the
    # changeset alone would leave every other writer — a future worker, a
    # backfill, a console — free to ignore it, and the thing being bounded is a
    # remote model's output.
    create constraint(:llm_call_log, :raw_response_is_bounded,
             check: "raw_response IS NULL OR octet_length(raw_response) <= 8192",
             prefix: "op"
           )

    # ⚠️ The outcome vocabulary is closed at the database, so a typo in a new
    # call site is a failed insert rather than a silent new category that
    # splits the metric nobody is watching closely.
    create constraint(:llm_call_log, :outcome_is_known,
             check:
               "outcome IN ('associated', 'unreadable_response', 'unexpected_shape', 'llm_error')",
             prefix: "op"
           )
  end

  def down do
    # ⚠️ The project's convention, and `scripts/security-squawk.sh` enforces it:
    # a migration that can wait on a lock says how long it will wait. Without
    # these, a DDL statement blocks behind any open transaction indefinitely and
    # every reader queues behind it — which is worse than failing and being
    # retried.
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    drop table(:llm_call_log, prefix: "op")
  end
end
