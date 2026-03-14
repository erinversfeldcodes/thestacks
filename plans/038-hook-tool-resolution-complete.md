# Completion: Hook & Script Tool Resolution Audit
**Issue**: #038
**Completed**: 2026-03-14
**Agent(s)**: platform-agent

## Summary
Audited all hooks and scripts for tool resolution. Added missing security tools to Brewfile and setup.sh. Hook scripts and cleanup-preview.sh were already fixed from earlier in-session work.

## Changes
- `Brewfile` — added trufflehog, syft, grype, dockle (with goodwithtech/r tap)
- `setup.sh` — added dbt-checkpoint pip install + missing-tool checks for trufflehog, syft, grype, dockle, dbt-checkpoint

## Already Fixed (confirmed present)
- All three hook scripts have project-local-first elm-format resolution
- `cleanup-preview.sh` uses `modal app stop` (not `delete`)
- `project_tools.py` uses list-based subprocess.run (no `shell=True`)
