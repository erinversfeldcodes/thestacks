# Issue #031: Public Deployment Risk Assessment

## Summary
Explore and document risks in deploying The Stacks as-is to the public internet. Cover authentication hardening, rate limiting, OWASP top 10, GDPR readiness, CSP headers, secret management, abuse vectors, infrastructure cost exposure, and any gaps between current state and production-ready.

## User Stories
No direct user stories — this is a security and operations assessment.

## Goal
A comprehensive risk assessment document identifying every significant risk in exposing the current codebase to the public internet, with severity ratings, mitigation recommendations, and a prioritised remediation plan. The output should make it clear what must be fixed before public launch vs. what can be deferred.

## Technical Requirements
- **Authentication & session management:** Review Guardian/JWT implementation, token expiry, refresh flow, brute-force protection, account lockout
- **OWASP Top 10:** Systematic check against current OWASP top 10 (injection, broken auth, sensitive data exposure, XXE, broken access control, security misconfiguration, XSS, insecure deserialisation, known vulnerabilities, insufficient logging)
- **Rate limiting:** API endpoints, upload endpoint abuse, login brute-force, scraper API
- **GDPR readiness:** Consent flows, data export, right to erasure, image retention, audit logging — gap analysis against current implementation
- **CSP & HTTP headers:** Review current CSP policy, HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy
- **Secret management:** Review how secrets are stored/accessed (Fly.io secrets, HMAC keys, Cloak encryption, API keys)
- **Abuse vectors:** Upload spam, vision API cost attacks, scraper abuse, partner API abuse, marketplace fraud
- **Infrastructure cost exposure:** What happens if traffic spikes? Fly.io auto-scaling costs, Modal API costs, Neon database costs. Is there a kill switch?
- **Dependencies & supply chain:** Review Elixir/Elm/Rust/Python dependency audit (known CVEs)
- **Sobelow scan:** Run Sobelow against the Elixir codebase and address findings
- Output: risk assessment document in `docs/security/` with severity matrix and remediation priorities

## Definition of Done
- [ ] OWASP Top 10 audit completed against current codebase
- [ ] Authentication and session management reviewed
- [ ] Rate limiting gaps identified
- [ ] GDPR readiness gap analysis completed
- [ ] CSP and HTTP security headers reviewed
- [ ] Secret management reviewed
- [ ] Abuse vector analysis completed
- [ ] Infrastructure cost exposure analysis completed
- [ ] Dependency/supply chain audit completed
- [ ] Sobelow scan run and findings documented
- [ ] Risk assessment document produced with severity matrix and prioritised remediation plan
- [ ] Standards compliance verified

## Dependencies
None — can run against current codebase at any time.

## Agent Assignment
security-agent (primary), platform-agent (infrastructure/cost analysis)

## Progress Notes
[Updated by agents during execution.]
