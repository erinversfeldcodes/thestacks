# Issue #393: Remove the dead 6PN bypass in MetricsAuth (no caller after ADR-021)

## Summary
`StacksWeb.Plugs.MetricsAuth` retains a 6PN (Fly private-network) bypass that let Fly's managed
Prometheus reach `/internal/metrics` without the bearer (Issue #232). ADR-021 (#253) replaced
scraping with a **push** (`Core.PromEx.MetricsPusher` → VictoriaMetrics), and #323 removed the
`[metrics]` block — so **no caller exercises the bypass today**. The Wave 10 comment pass documented
this honestly; the dead bypass code itself remains. Dead auth-relaxing code is a standing latent risk.

## Goal
`/internal/*` is guarded by the bearer alone, with no IP-shaped bypass that nothing uses — removing a
latent auth-relaxation path. `scripts/check-slo-gate.sh` (the one remaining `/internal/metrics`
caller) continues to pass by presenting the bearer.

## Scope Check
One plug + its test. Security-adjacent — verify the SLO-gate caller path before/after. Under the bar.

## Technical Requirements
1. Confirm the only live caller of `/internal/metrics` (`scripts/check-slo-gate.sh`) authenticates
   with the bearer, not the 6PN bypass.
2. Remove the bypass branch + its now-inaccurate comment; keep the bearer requirement.
3. Test: a request with no bearer and no `fly-client-ip` is now **rejected** (the bypass is gone).

## Definition of Done
- [x] Bypass removed; bearer-only guard remains — evidence: `7392f527` ("remove the dead 6PN metrics-auth bypass so every internal route requires the bearer") + rejection test in the same commit
- [x] SLO-gate caller still green — evidence: finalize `just ci` 2026-08-08 code gates green (the SLO gate runs inside it)
- [x] `staff-review` verdict recorded — see Wave 11 close-out below

## Dependencies
Surfaced by the Wave 10 #323 comment cleanup. Sibling of the metrics-pipeline work. **Assigned to Wave 11.**

## Progress Notes
Filed 2026-08-06. Dead code, not a live vuln (bearer still required on the public path); removing it
closes a latent bypass.


## Wave 11 close-out (2026-08-09)
staff-review (Mode B shadow, 2026-08-09): **LGTM** — dead trust path removed with a rejection test; the SLO caller proves nothing depended on it.
