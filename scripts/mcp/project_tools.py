#!/usr/bin/env python3
"""
The Stacks — Project Tools MCP Server

Exposes project-management operations as MCP tools available in every
Claude Code session: reading/writing issues, checking plan status,
looking up agent specs, and creating new issues from the template.

Entry point: scripts/mcp/server.sh (uses the local .venv)
Registration: .claude/settings.json mcpServers.project-tools
"""

from __future__ import annotations

import datetime
import json
import re
import subprocess
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
ISSUES_DIR = REPO_ROOT / "issues"
PLANS_DIR = REPO_ROOT / "plans"
AGENTS_DIR = REPO_ROOT / "docs" / "agents"

mcp = FastMCP("project-tools")


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _find_issue_file(number: int) -> Path | None:
    matches = list(ISSUES_DIR.glob(f"{number:03d}-*.md"))
    return matches[0] if matches else None


def _find_plan_file(number: int) -> Path | None:
    matches = list(PLANS_DIR.glob(f"{number:03d}-*.md"))
    return matches[0] if matches else None


def _find_state_file(number: int) -> Path | None:
    """Find an active state file (excludes *-state-complete.json)."""
    matches = [
        p
        for p in PLANS_DIR.glob(f"{number:03d}-*-state.json")
        if not p.name.endswith("-state-complete.json")
    ]
    return matches[0] if matches else None


def _parse_sections(lines: list[str]) -> dict[str, list[str]]:
    """Split markdown into H2 sections → list of content lines."""
    sections: dict[str, list[str]] = {}
    current: str | None = None
    for line in lines:
        if re.match(r"^## ", line):
            current = line[3:].strip()
            sections[current] = []
        elif current is not None:
            sections[current].append(line)
    return sections


def _section_text(sections: dict[str, list[str]], name: str) -> str:
    return "\n".join(sections.get(name, [])).strip()


def _parse_issue(path: Path) -> dict[str, Any]:
    text = path.read_text()
    lines = text.splitlines()

    # Header: # Issue #NNN: Title
    number = 0
    title = ""
    if lines:
        m = re.match(r"^# Issue #(\d+):\s*(.+)$", lines[0])
        if m:
            number = int(m.group(1))
            title = m.group(2).strip()

    sections = _parse_sections(lines[1:])

    # DoD items
    dod_items: list[dict[str, Any]] = []
    for line in sections.get("Definition of Done", []):
        m_done = re.match(r"^- \[x\] (.+)$", line, re.IGNORECASE)
        m_todo = re.match(r"^- \[ \] (.+)$", line)
        if m_done:
            dod_items.append({"text": m_done.group(1), "done": True})
        elif m_todo:
            dod_items.append({"text": m_todo.group(1), "done": False})

    done_count = sum(1 for d in dod_items if d["done"])
    status = "complete" if dod_items and done_count == len(dod_items) else "open"

    # Progress notes
    progress_notes = [
        line[2:]  # strip leading "- "
        for line in sections.get("Progress Notes", [])
        if re.match(r"^- \d{4}-\d{2}-\d{2}:", line)
    ]

    # Dependencies
    deps_raw = _section_text(sections, "Dependencies")
    dependencies = [
        line.lstrip("- ").strip()
        for line in deps_raw.splitlines()
        if line.startswith("-")
    ]

    return {
        "number": number,
        "title": title,
        "summary": _section_text(sections, "Summary"),
        "status": status,
        "agent_assignment": _section_text(sections, "Agent Assignment"),
        "dod_items": dod_items,
        "dod_completion": f"{done_count}/{len(dod_items)}",
        "dependencies": dependencies,
        "progress_notes": progress_notes,
    }


def _extract_summary(domain: str, output: str) -> str:
    """Extract a human-readable test summary from command output."""
    patterns: dict[str, re.Pattern[str]] = {
        "elixir": re.compile(r"\d+ tests?, \d+ failures?"),
        "elm": re.compile(r"TEST RUN (PASSED|FAILED)|\d+ passed"),
        "rust": re.compile(r"test result:.*"),
        "python": re.compile(r"\d+ passed|FAILED"),
    }

    pattern = patterns.get(domain)
    if pattern:
        for line in reversed(output.splitlines()):
            m = pattern.search(line)
            if m:
                return m.group(0).strip()

    # Fall back to the last non-empty line.
    for line in reversed(output.splitlines()):
        stripped = line.strip()
        if stripped:
            return stripped

    return "No output"


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------


@mcp.tool()
def get_issue(number: int) -> dict[str, Any]:
    """
    Read and parse an issue file by number.

    Returns structured metadata: title, summary, DoD items with completion
    status, progress notes, agent assignment, and dependencies.
    """
    path = _find_issue_file(number)
    if path is None:
        return {"error": f"Issue #{number:03d} not found in {ISSUES_DIR}"}
    return _parse_issue(path)


@mcp.tool()
def list_issues(status: str = "all") -> list[dict[str, Any]]:
    """
    List all issues with summary information.

    Args:
        status: "open", "complete", or "all" (default).

    Returns each issue's number, title, status, and DoD completion ratio.
    """
    if status not in ("open", "complete", "all"):
        return [
            {"error": f"Invalid status '{status}'. Use 'open', 'complete', or 'all'."}
        ]

    results = []
    for path in sorted(ISSUES_DIR.glob("[0-9][0-9][0-9]-*.md")):
        try:
            parsed = _parse_issue(path)
            if status == "all" or parsed["status"] == status:
                results.append(
                    {
                        "number": parsed["number"],
                        "title": parsed["title"],
                        "status": parsed["status"],
                        "dod_completion": parsed["dod_completion"],
                    }
                )
        except Exception as exc:
            results.append({"file": path.name, "error": str(exc)})

    return results


@mcp.tool()
def next_issue_number() -> int:
    """
    Return the next available issue number.

    Scans issues/ and returns max(existing numbers) + 1.
    """
    existing = [
        int(m.group(1))
        for path in ISSUES_DIR.glob("[0-9][0-9][0-9]-*.md")
        if (m := re.match(r"^(\d+)-", path.name))
    ]
    return max(existing, default=0) + 1


@mcp.tool()
def update_progress(number: int, note: str) -> dict[str, Any]:
    """
    Append a timestamped progress note to an issue's Progress Notes section.
    Also appends to state.notes[] if an active state file exists for this issue.

    Args:
        number: Issue number.
        note: Note text — the date prefix (YYYY-MM-DD) is added automatically.

    Returns {"ok": true, "appended": "- YYYY-MM-DD: <note>"} on success.
    """
    if not note.strip():
        return {"error": "Note must not be empty."}

    path = _find_issue_file(number)
    if path is None:
        return {"error": f"Issue #{number:03d} not found."}

    text = path.read_text()
    if "## Progress Notes" not in text:
        return {"error": "Issue file has no '## Progress Notes' section."}

    today = datetime.date.today().isoformat()
    new_line = f"- {today}: {note.strip()}"

    updated = text.rstrip("\n") + "\n" + new_line + "\n"
    path.write_text(updated)

    # Also append to state file notes[] if one exists.
    state_path = _find_state_file(number)
    if state_path is not None:
        import json

        state = json.loads(state_path.read_text())
        state.setdefault("notes", []).append(new_line)
        state["updated_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        state_path.write_text(json.dumps(state, indent=2) + "\n")

    return {"ok": True, "appended": new_line}


@mcp.tool()
def get_plan_status(issue_number: int) -> dict[str, Any]:
    """
    Return the execution status of a plan for an issue.

    Prefers the machine-readable state file (`plans/NNN-*-state.json`) if it
    exists, falling back to parsing the plan markdown for phase headings.

    Args:
        issue_number: The issue number whose plan to read.

    Returns plan existence, status, current phase, and phase detail.
    """

    # Prefer state file — it is the authoritative machine-readable source.
    state_path = _find_state_file(issue_number)
    if state_path is not None:
        state = json.loads(state_path.read_text())
        return {
            "exists": True,
            "source": "state_file",
            "file": state_path.name,
            **state,
        }

    # Fall back to plan markdown.
    plan_path = _find_plan_file(issue_number)
    if plan_path is None:
        return {"exists": False, "issue_number": issue_number}

    text = plan_path.read_text()

    plan_status = "unknown"
    for line in text.splitlines()[:20]:
        m = re.match(r"^\*\*Status\*\*:\s*(.+)$", line)
        if m:
            plan_status = m.group(1).strip()
            break

    phases = []
    phase_re = re.compile(r"^#{2,3}\s+(?:Phase\s+)?(\d+[A-Za-z]?)\b", re.IGNORECASE)
    for line in text.splitlines():
        m = phase_re.match(line)
        if m:
            phases.append({"id": m.group(1)})

    result: dict[str, Any] = {
        "exists": True,
        "source": "plan_markdown",
        "file": plan_path.name,
        "plan_status": plan_status,
    }
    if phases:
        result["phases"] = phases

    return result


@mcp.tool()
def get_agent(name: str) -> dict[str, Any]:
    """
    Read an agent spec and return its role, owned domains, and full content.

    Args:
        name: Agent filename stem, e.g. "elixir-agent", "orchestrator-agent",
              "python-reviewer". The "-agent" suffix is optional.

    Returns role, owned_domains, and raw_content for constructing invocation prompts.
    """
    candidates = [
        AGENTS_DIR / f"{name}.md",
        AGENTS_DIR / f"{name}-agent.md",
    ]
    path = next((p for p in candidates if p.exists()), None)
    if path is None:
        available = sorted(p.stem for p in AGENTS_DIR.glob("*.md"))
        return {"error": f"Agent '{name}' not found.", "available": available}

    text = path.read_text()
    lines = text.splitlines()
    title = lines[0].lstrip("# ").strip() if lines else ""
    sections = _parse_sections(lines[1:])

    return {
        "name": path.stem,
        "title": title,
        "role": _section_text(sections, "Role"),
        "owned_domains": _section_text(sections, "Owned Domains"),
        "raw_content": text,
    }


@mcp.tool()
def run_test_suite(domain: str, worktree_path: str | None = None) -> dict[str, Any]:
    """
    Run the test suite for a given domain and return structured results.

    Args:
        domain: One of "elixir", "elm", "rust", "python".
        worktree_path: Optional path override for worktree isolation
                       (defaults to REPO_ROOT).

    Returns a dict with domain, passed, summary, output, and command keys.
    """
    domain_config: dict[str, tuple[str, str]] = {
        "elixir": ("mix test", "apps/core"),
        "elm": ("npx elm-test", "frontend"),
        "rust": ("cargo test", "apps/scraper"),
        "python": ("pytest", "apps/vision"),
    }

    if domain not in domain_config:
        supported = ", ".join(sorted(domain_config.keys()))
        return {"error": f"Unsupported domain '{domain}'. Supported: {supported}"}

    command, rel_dir = domain_config[domain]
    base = Path(worktree_path) if worktree_path else REPO_ROOT
    cwd = base / rel_dir

    if not cwd.is_dir():
        return {"error": f"Working directory does not exist: {cwd}"}

    try:
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=300,
            cwd=str(cwd),
        )
    except subprocess.TimeoutExpired:
        return {
            "domain": domain,
            "passed": False,
            "summary": "Test run timed out after 300 seconds",
            "output": "",
            "command": command,
        }

    combined_output = result.stdout + result.stderr
    # Truncate to last 5000 chars if very long.
    if len(combined_output) > 5000:
        combined_output = combined_output[-5000:]

    return {
        "domain": domain,
        "passed": result.returncode == 0,
        "summary": _extract_summary(domain, combined_output),
        "output": combined_output,
        "command": command,
    }


@mcp.tool()
def create_issue(
    title: str,
    summary: str,
    goal: str = "",
    technical_requirements: str = "",
    dod_items: list[str] | None = None,
    dependencies: str = "None.",
    agent_assignment: str = "",
) -> dict[str, Any]:
    """
    Create a new issue file from the project template.

    Args:
        title: Short descriptive title (without the issue number prefix).
        summary: 1-2 sentence description of what needs to be done.
        goal: What success looks like (optional).
        technical_requirements: Technical details and constraints (optional).
        dod_items: List of DoD criterion strings. Generic defaults if omitted.
        dependencies: Other issues or infrastructure required first.
        agent_assignment: Which specialist agent(s) should handle this.

    Returns {"number": NNN, "file": "issues/NNN-slug.md"}.
    """
    if not title.strip():
        return {"error": "Title must not be empty."}
    if not summary.strip():
        return {"error": "Summary must not be empty."}

    number = next_issue_number()
    slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    filename = f"{number:03d}-{slug}.md"
    path = ISSUES_DIR / filename

    if path.exists():
        return {"error": f"File already exists: {filename}"}

    if not dod_items:
        dod_items = ["[Specific, measurable criterion]", "Tests written and passing"]
    dod_section = "\n".join(f"- [ ] {item}" for item in dod_items)

    today = datetime.date.today().isoformat()

    content = f"""# Issue #{number:03d}: {title}

## Summary
{summary.strip()}

## User Stories
Not directly tied to a user story.

## Goal
{goal.strip() or "[What does success look like?]"}

## Technical Requirements
{technical_requirements.strip() or "[Specific technical details, constraints, architecture references.]"}

## Definition of Done
{dod_section}

## Dependencies
{dependencies.strip()}

## Agent Assignment
{agent_assignment.strip() or "[Which specialist agent(s) should handle this.]"}

## Progress Notes
<!-- Updated by agents during execution -->
- {today}: Issue created.
"""

    path.write_text(content)
    return {"number": number, "file": str(path.relative_to(REPO_ROOT))}


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    mcp.run()
