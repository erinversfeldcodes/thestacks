# Issue #034: Public Deployment Risk Remediation

## Summary
Address the risks identified in the #031 risk assessment. Implement mitigations for all findings rated as must-fix-before-launch. The specific scope of this issue will be determined by #031's output.

## User Stories
No direct user stories — this is security and infrastructure hardening work.

## Goal
All risks identified in #031 that are rated as must-fix-before-public-launch are remediated. The codebase is ready for public internet exposure with no known critical or high-severity gaps.

## Technical Requirements
- Scope is determined by the risk assessment document produced by #031 (`docs/security/` output)
- Implement all mitigations for findings rated as "must fix before launch"
- For each finding: implement the fix, write tests proving the fix works, and update the risk assessment document to mark the finding as resolved
- Likely areas (to be confirmed by #031):
  - Rate limiting on API endpoints and upload flow
  - Authentication hardening (brute-force protection, session management)
  - CSP and HTTP security header improvements
  - Infrastructure cost guardrails (spending alerts, auto-scaling limits)
  - Abuse vector mitigations (upload spam, API abuse)
  - Dependency audit fixes (CVE remediation)
  - Sobelow finding fixes
- Findings rated as "can defer" should be documented as future work but not blocked on
- Dependencies: #031 must complete first to define the full scope

## Definition of Done
- [ ] All must-fix-before-launch findings from #031 addressed
- [ ] Each fix has corresponding tests
- [ ] Risk assessment document updated with resolution status for each finding
- [ ] Deferred findings documented as future work with justification
- [ ] Full test suite passes after all changes
- [ ] Standards compliance verified

## Dependencies
- #031 (Public Deployment Risk Assessment — defines the scope of this issue)

## Agent Assignment
Determined by #031 findings. Likely: security-agent, platform-agent, elixir-agent (depending on which domains are affected).

## Progress Notes
[Updated by agents during execution.]
