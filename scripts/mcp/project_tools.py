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
import os
import re
import subprocess
from pathlib import Path
from typing import Any

from dod_templates import DOD_TEMPLATES, DOMAIN_AGENTS
from mcp.server.fastmcp import FastMCP

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
ISSUES_DIR = REPO_ROOT / "issues"
PLANS_DIR = REPO_ROOT / "plans"
AGENTS_DIR = REPO_ROOT / "docs" / "agents"
FEEDBACK_DIR = REPO_ROOT / "docs" / "agents" / "feedback"

mcp = FastMCP("project-tools")


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

    number = 0
    title = ""
    if lines:
        m = re.match(r"^# Issue #(\d+):\s*(.+)$", lines[0])
        if m:
            number = int(m.group(1))
            title = m.group(2).strip()

    sections = _parse_sections(lines[1:])

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

    progress_notes = [
        line[2:]  # strip leading "- "
        for line in sections.get("Progress Notes", [])
        if re.match(r"^- \d{4}-\d{2}-\d{2}:", line)
    ]

    deps_raw = _section_text(sections, "Dependencies")
    dependencies = [
        line.lstrip("- ").strip() for line in deps_raw.splitlines() if line.startswith("-")
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

    for line in reversed(output.splitlines()):
        stripped = line.strip()
        if stripped:
            return stripped

    return "No output"


def _parse_feedback_file(path: Path) -> list[dict[str, Any]]:
    """Parse a feedback log file and return open entries as dicts."""
    text = path.read_text()

    marker = "<!-- Entries below this line -->"
    marker_idx = text.find(marker)
    if marker_idx == -1:
        return []
    body = text[marker_idx + len(marker) :]

    agent = path.stem

    entry_re = re.compile(r"^## ", re.MULTILINE)
    parts = entry_re.split(body)

    heading_re = re.compile(r"^(\d{4}-\d{2}-\d{2})\s*—\s*Issue\s*#(\d+),?\s*Phase\s*(\S+)")
    field_re = re.compile(r"^\*\*(.+?):\*\*\s*(.+)$", re.MULTILINE)

    field_map = {
        "Reviewer axis": "reviewer_axis",
        "Finding": "finding",
        "Root cause": "root_cause",
        "Prompt change needed": "prompt_change_needed",
        "Status": "status",
    }

    results: list[dict[str, Any]] = []
    for part in parts:
        part = part.strip()
        if not part:
            continue

        first_line = part.split("\n", 1)[0]
        hm = heading_re.match(first_line)
        if not hm:
            continue

        entry: dict[str, Any] = {
            "agent": agent,
            "date": hm.group(1),
            "issue": f"#{hm.group(2)}",
            "phase": hm.group(3),
        }

        for fm in field_re.finditer(part):
            key = field_map.get(fm.group(1))
            if key:
                entry[key] = fm.group(2).strip()

        if entry.get("status", "").lower() != "open":
            continue

        results.append(entry)

    return results


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
        return [{"error": f"Invalid status '{status}'. Use 'open', 'complete', or 'all'."}]

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

    state_path = _find_state_file(number)
    if state_path is not None:
        import json

        state = json.loads(state_path.read_text())
        state.setdefault("notes", []).append(new_line)
        state["updated_at"] = datetime.datetime.now(datetime.UTC).isoformat()
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

    state_path = _find_state_file(issue_number)
    if state_path is not None:
        state = json.loads(state_path.read_text())
        return {
            "exists": True,
            "source": "state_file",
            "file": state_path.name,
            **state,
        }

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
    domain_config: dict[str, tuple[list[str], str]] = {
        "elixir": (["mix", "test"], "apps/core"),
        "elm": (["npx", "elm-test"], "frontend"),
        "rust": (["cargo", "test"], "apps/scraper"),
        "python": (["pytest"], "apps/vision"),
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
    if len(combined_output) > 5000:
        combined_output = combined_output[-5000:]

    return {
        "domain": domain,
        "passed": result.returncode == 0,
        "summary": _extract_summary(domain, combined_output),
        "output": combined_output,
        "command": command,
    }


def _worktree_info(issue_number: int, phase: str) -> tuple[Path, str]:
    """Return (worktree_path, branch_name) for the given issue and phase."""
    label = f"{issue_number:03d}-phase-{phase}"
    path = REPO_ROOT / ".claude" / "worktrees" / label
    branch = f"worktree/{label}"
    return path, branch


@mcp.tool()
def create_worktree(issue_number: int, phase: str) -> dict[str, Any]:
    """
    Create a git worktree for a specialist agent to work in isolation.

    Creates a worktree at .claude/worktrees/<issue>-phase-<phase> branched
    from the current HEAD of the active branch.

    Args:
        issue_number: The issue number (e.g., 14).
        phase: The phase identifier (e.g., "2" or "2a").

    Returns {"path": "<absolute path>", "branch": "worktree/<issue>-phase-<phase>"}
    """
    wt_path, branch = _worktree_info(issue_number, phase)

    if wt_path.exists():
        return {"error": f"Worktree already exists at {wt_path}"}

    wt_path.parent.mkdir(parents=True, exist_ok=True)

    result = subprocess.run(
        ["git", "worktree", "add", str(wt_path), "-b", branch],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
    )

    if result.returncode != 0:
        return {
            "error": result.stderr.strip() or f"git worktree add failed (exit {result.returncode})"
        }

    return {"path": str(wt_path), "branch": branch}


@mcp.tool()
def remove_worktree(issue_number: int, phase: str) -> dict[str, Any]:
    """
    Remove a git worktree and its associated branch.

    Args:
        issue_number: The issue number.
        phase: The phase identifier.

    Returns {"ok": true, "removed_path": "...", "removed_branch": "..."}
    """
    wt_path, branch = _worktree_info(issue_number, phase)

    if not wt_path.exists():
        return {"error": f"No worktree at {wt_path}"}

    result = subprocess.run(
        ["git", "worktree", "remove", str(wt_path), "--force"],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
    )

    if result.returncode != 0:
        return {
            "error": result.stderr.strip()
            or f"git worktree remove failed (exit {result.returncode})"
        }

    result = subprocess.run(
        ["git", "branch", "-D", branch],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
    )

    if result.returncode != 0:
        return {
            "error": result.stderr.strip() or f"git branch -D failed (exit {result.returncode})"
        }

    return {"ok": True, "removed_path": str(wt_path), "removed_branch": branch}


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
{technical_requirements.strip() or "[Specific technical details, constraints, references.]"}

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


@mcp.tool()
def draft_issue(
    title: str,
    roadmap_context: str,
    domains: list[str],
) -> dict[str, Any]:
    """
    Draft a new issue with auto-populated DoD items, agent assignments,
    and suggested dependencies based on the specified domains.

    Returns a dict matching the create_issue input shape, plus a
    suggested_dependencies field for human review.

    Args:
        title: Short descriptive title for the issue.
        roadmap_context: 1-2 sentence description of what needs to be done
                         and why (becomes the summary).
        domains: List of domain strings (e.g. ["elixir", "database"]).
    """
    seen: set[str] = set()
    combined_dod: list[str] = []
    for domain in domains:
        for item in DOD_TEMPLATES.get(domain, []):
            if item not in seen:
                seen.add(item)
                combined_dod.append(item)

    agent_lines: list[str] = []
    agent_names: set[str] = set()
    for domain in domains:
        agent = DOMAIN_AGENTS.get(domain)
        if agent:
            agent_names.add(agent)
            agent_lines.append(f"- **{agent}** for {domain}")
    agent_assignment_text = "\n".join(agent_lines) if agent_lines else ""

    open_issues = list_issues(status="open")
    suggested_deps: list[dict[str, str]] = []
    dep_lines: list[str] = []
    for issue in open_issues:
        if "error" in issue:
            continue
        issue_title = issue.get("title", "")
        issue_title_lower = issue_title.lower()

        matching_reasons: list[str] = []
        for domain in domains:
            if domain.lower() in issue_title_lower:
                matching_reasons.append(f"domain: {domain}")

        issue_path = _find_issue_file(issue["number"])
        if issue_path is not None:
            full_issue = _parse_issue(issue_path)
            issue_agent_text = full_issue.get("agent_assignment", "")
            for agent in agent_names:
                if agent in issue_agent_text:
                    matching_reasons.append(f"agent: {agent}")

        if matching_reasons:
            reason = ", ".join(matching_reasons)
            dep_lines.append(
                f"- Issue #{issue['number']:03d} ({issue_title}) — potential overlap: [{reason}]"
            )
            suggested_deps.append(
                {
                    "issue": issue["number"],
                    "title": issue_title,
                    "reason": reason,
                }
            )

    dependencies_text = "\n".join(dep_lines) if dep_lines else "None."

    standards_map: dict[str, list[str]] = {
        "elixir": [
            "docs/agents/standards/code-quality.md",
            "docs/agents/standards/testing.md",
        ],
        "elm": ["docs/agents/standards/code-quality.md"],
        "rust": ["docs/agents/standards/code-quality.md"],
        "python": [
            "docs/agents/standards/code-quality.md",
            "docs/agents/standards/security.md",
        ],
        "platform": ["docs/agents/standards/code-quality.md"],
        "database": [
            "docs/agents/standards/code-quality.md",
            "docs/agents/standards/testing.md",
        ],
    }

    ref_paths: set[str] = set()
    for domain in domains:
        for p in standards_map.get(domain, []):
            ref_paths.add(p)

    refs_section = "\n".join(f"- {p}" for p in sorted(ref_paths))
    technical_requirements_text = (
        "### Standards References\n"
        f"{refs_section}\n\n"
        "[Additional technical requirements to be filled in by human]"
    )

    return {
        "title": title,
        "summary": roadmap_context,
        "goal": "[To be refined by human]",
        "technical_requirements": technical_requirements_text,
        "dod_items": combined_dod,
        "dependencies": dependencies_text,
        "agent_assignment": agent_assignment_text,
        "suggested_dependencies": suggested_deps,
    }


@mcp.tool()
def get_feedback_summary(agent_name: str | None = None) -> list[dict[str, Any]]:
    """
    Return open feedback entries for specialist agents.

    Reads structured entries from docs/agents/feedback/<agent-name>.md files.
    Only entries with status "open" are returned; applied entries are skipped.

    Args:
        agent_name: Optional agent name (e.g. "elixir-agent"). If None,
                    returns open entries across all agents.

    Returns a list of dicts with keys: agent, date, issue, phase,
    reviewer_axis, finding, root_cause, prompt_change_needed, status.
    """
    if agent_name is not None:
        path = FEEDBACK_DIR / f"{agent_name}.md"
        if not path.exists():
            return []
        return _parse_feedback_file(path)

    results: list[dict[str, Any]] = []
    if FEEDBACK_DIR.is_dir():
        for path in sorted(FEEDBACK_DIR.glob("*.md")):
            results.extend(_parse_feedback_file(path))
    return results


def _parse_deploy_output(output: str) -> dict[str, Any]:
    """Parse deploy-preview.sh output for PASS/FAIL lines and preview URL.

    Returns a dict with keys: passed, preview_url, pass_lines, fail_lines.
    """
    pass_lines: list[str] = []
    fail_lines: list[str] = []
    preview_url: str | None = None

    for line in output.splitlines():
        stripped = line.strip()
        if stripped.startswith("PASS deploy:"):
            pass_lines.append(stripped)
        elif stripped.startswith("FAIL deploy:"):
            fail_lines.append(stripped)
        # Extract the preview URL from the deploy output.
        # The script prints lines like: "    Core app:    stacks-core-pr-xxx"
        # and the URL is "https://<app>.fly.dev".
        if "Core app:" in line and not preview_url:
            parts = line.split("Core app:")
            if len(parts) == 2:
                app_name = parts[1].strip()
                if app_name:
                    preview_url = f"https://{app_name}.fly.dev"

    for line in output.splitlines():
        if "fly.dev" in line and "https://" in line:
            url_match = re.search(r"https://[\w.-]+\.fly\.dev", line)
            if url_match and not preview_url:
                preview_url = url_match.group(0)

    passed = len(fail_lines) == 0 and len(pass_lines) > 0

    return {
        "passed": passed,
        "preview_url": preview_url,
        "pass_lines": pass_lines,
        "fail_lines": fail_lines,
    }


@mcp.tool()
def run_e2e_gate(issue_number: int) -> dict[str, Any]:
    """Deploy a preview environment and run E2E against it, via
    scripts/deploy-preview.sh (Neon branch -> Fly preview -> Playwright ->
    DAST -> cleanup). Output is parsed for PASS/FAIL lines.

    Args: issue_number (derives the preview branch name).
    Returns: {passed, pass_lines, fail_lines, preview_url, log_path}.
    """
    deploy_script = REPO_ROOT / "scripts" / "deploy-preview.sh"
    if not deploy_script.exists():
        return {"error": f"Deploy script not found: {deploy_script}"}

    try:
        branch_result = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            timeout=10,
            cwd=str(REPO_ROOT),
        )
        branch = branch_result.stdout.strip() if branch_result.returncode == 0 else ""
    except subprocess.TimeoutExpired:
        branch = ""

    cmd = ["bash", str(deploy_script)]
    if branch:
        cmd.extend(["--branch", branch])

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=900,  # 15 minutes — deploy + E2E + DAST can be slow
            cwd=str(REPO_ROOT),
            env={**os.environ},
        )
    except subprocess.TimeoutExpired:
        return {
            "passed": False,
            "preview_url": None,
            "summary": "E2E gate timed out after 900 seconds",
            "pass_lines": [],
            "fail_lines": ["FAIL deploy: timed out"],
            "output": "",
        }

    combined_output = result.stdout + result.stderr
    if len(combined_output) > 5000:
        combined_output = combined_output[-5000:]

    parsed = _parse_deploy_output(result.stdout + result.stderr)

    if parsed["passed"]:
        summary = f"E2E gate passed ({len(parsed['pass_lines'])} checks passed)"
    else:
        summary = (
            f"E2E gate failed ({len(parsed['fail_lines'])} failures, "
            f"{len(parsed['pass_lines'])} passed)"
        )

    return {
        "passed": parsed["passed"],
        "preview_url": parsed["preview_url"],
        "summary": summary,
        "pass_lines": parsed["pass_lines"],
        "fail_lines": parsed["fail_lines"],
        "output": combined_output,
    }


@mcp.tool()
def generate_image(
    prompt: str,
    output_filename: str = "generated.png",
    width: int = 1024,
    height: int = 1024,
) -> str:
    """Generate an image using Flux Schnell on Replicate.

    Args:
        prompt: Text description of the image to generate.
        output_filename: Filename to save in the project root (e.g. "door-concept-1.png").
        width: Image width in pixels (default 1024).
        height: Image height in pixels (default 1024).

    Returns:
        Absolute path to the saved image file.
    """
    import requests as http_requests

    token = os.environ.get("REPLICATE_API_TOKEN") or os.environ.get("REPLICATE_TOKEN")
    if not token:
        return "Error: REPLICATE_API_TOKEN or REPLICATE_TOKEN not set in environment"

    try:
        import replicate

        client = replicate.Client(api_token=token)
        output = client.run(
            "black-forest-labs/flux-schnell",
            input={
                "prompt": prompt,
                "width": width,
                "height": height,
                "num_outputs": 1,
                "output_format": "png",
            },
        )

        image_url = None
        if isinstance(output, list) and len(output) > 0:
            item = output[0]
            if hasattr(item, "url"):
                image_url = item.url
            elif isinstance(item, str):
                image_url = item
        elif isinstance(output, str):
            image_url = output

        if not image_url:
            return f"Error: Unexpected output format from Replicate: {type(output)}"

        out_path = REPO_ROOT / output_filename
        resp = http_requests.get(image_url, timeout=60)
        resp.raise_for_status()
        out_path.write_bytes(resp.content)

        return f"Image saved to {out_path}"

    except Exception as e:
        return f"Error generating image: {e}"


if __name__ == "__main__":
    mcp.run()
