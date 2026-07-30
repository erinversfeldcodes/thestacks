# `:deployed_only` — tests that need a real deployed stack (Fly preview) and
# cannot pass against a local/CI Phoenix. Run them by pointing at a deployment
# and passing `--include deployed_only`.
#
# ⚠️ `:sla` was excluded here too, with no comment (Issue #330). Its single user
# — the SSE-stream latency assertion in `upload_pipeline_test.exs` — was the
# whole suite's only latency test, and permanently excluding it meant the suite
# had no latency coverage at all while appearing to. It now runs, with a
# threshold sized to the regression rather than to the measurement. Do not
# re-add a tag here without saying, in this file, what it excludes and why.
ExUnit.configure(exclude: [:deployed_only])
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Core.Repo, :manual)
