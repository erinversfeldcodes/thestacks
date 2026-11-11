defmodule Core.Repo.Migrations.StopPromisingATokenSplitTheProviderNeverSends do
  @moduledoc """
      Drop `op.llm_call_log.prompt_tokens` and `completion_tokens`.

      ⛔ TWO COLUMNS THAT WERE PERMANENTLY NULL **AND** THE WRONG SHAPE. They
      had no writer anywhere — two declarations and two `cast/3` entries in
      `call_log.ex`, no assignment in `record_call/5`, the test helper, or the
      factory. A review found them; checking what the provider actually sends is
      what decided the fix.

      ⚖️ Together reports **only `total_tokens`** — `charge_for/1` matches
      `%{"usage" => %{"total_tokens" => tokens}}` and the mock builds the same
      single key. So there is no prompt/completion split anywhere in the request
      path, and filling these two columns would have meant inventing a division
      the provider does not give us.

      ⬛ An always-NULL column is worse than an absent one: absence prompts a
      question, NULL answers it wrongly. The specific risk was concrete — the
      next person building the LLM eval corpus finds `prompt_tokens` in the
      schema, groups or filters on it, and gets a silently empty result. Same
      defect as `total` being written and never read in the vision baseline.

      ⚠️ `total_tokens` is NOT added here, deliberately. It needs a writer, and
      the only path to one is widening `complete/2`'s return — which has **five**
      call sites plus the behaviour module and the mock, and three of them (the
      health-check smoke, two circuit-breaker tests) have no use for usage data.
      That is a seam change, not a column addition, so it is its own issue
      rather than a passenger on this branch. Dropping the lie today costs
      nothing and stops the schema misleading a reader; adding the column before
      something reads it would just be a better-named always-NULL column.
  """
  use Ecto.Migration

  @breaking_ok "both columns have no writer and have been NULL since they were created; no N-1 reader can observe a value that was never set"

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:llm_call_log, prefix: "op") do
      remove :prompt_tokens
      remove :completion_tokens
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:llm_call_log, prefix: "op") do
      add :prompt_tokens, :integer
      add :completion_tokens, :integer
    end
  end
end
