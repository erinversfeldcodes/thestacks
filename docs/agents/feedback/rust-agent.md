# Feedback Log: rust-agent

> Running log of reviewer findings that indicate gaps in this specialist's prompt.
> Each entry follows a structured format to enable systematic prompt improvements.
>
> **Entry format:**
> ```
> ## YYYY-MM-DD — Issue #NNN, Phase N
> **Reviewer axis:** [which review axis caught this]
> **Finding:** [what the reviewer flagged]
> **Root cause:** [why the specialist missed it — what's lacking in the prompt]
> **Prompt change needed:** [specific text to add/change in the agent's .md file]
> **Status:** open | applied (commit: abc1234)
> ```
>
> **Workflow:**
> 1. Orchestrator appends entries when reviewer returns NEEDS_REVISION
> 2. `mcp__project-tools__get_feedback_summary("rust-agent")` reads open entries
> 3. Human reviews and applies prompt changes periodically
> 4. Mark entries as `applied` with commit reference

<!-- Entries below this line -->
