# Issue #135: SSRF TOCTOU Risk — DNS Rebinding Not Fully Mitigated

## Priority: P2 Medium

## Problem

`apps/vision/app/services/url_validator.py` validates a URL against SSRF by:
1. Checking the hostname is not in a blocklist.
2. Resolving the hostname via `socket.getaddrinfo` and verifying the IP is globally routable.

However, this validation is performed **before** `httpx` makes the actual HTTP request. When `httpx.AsyncClient` makes the request, it performs a fresh DNS resolution. A DNS rebinding attack can return a private IP address on the second resolution, bypassing the validator.

The file already acknowledges this at line 103–106 with a `NOTE: TOCTOU risk` comment. The comment says this is "deferred to a follow-up issue." That follow-up issue does not yet exist.

This is a known SSRF defence gap in a service that fetches arbitrary user-controlled URLs (cover image URLs from Open Library, Google Books, or partner submissions).

## Impact

An attacker who controls a DNS record can make the vision service fetch internal endpoints (e.g., `169.254.169.254` AWS metadata, `100.64.x.x` Fly.io internal services) by racing the 60-second TTL window between validation and fetch. The vision service runs on Modal (public HTTPS) and fetches cover URLs submitted as part of associate requests — this is a real attack surface.

## Evidence

- `apps/vision/app/services/url_validator.py:103–106` — explicit TOCTOU acknowledgement, no follow-up issue.
- `apps/vision/app/main.py:84–106` — `_download_image` uses a separate `httpx.AsyncClient` that re-resolves DNS.
- No custom httpx transport that reuses the pre-validated IP address.

## Suggested Fix

Implement a custom `httpx` transport (or use the `httpx_auth` / transport override mechanism) that:
1. Pre-resolves the hostname to a specific IP using the already-validated address from `validate_image_url`.
2. Connects directly to that IP (bypassing DNS on the actual HTTP request) with an `Host` header set to the original hostname.

Alternatively, use a library like `ssrf-proxy` or implement a custom `httpcore.SyncConnectionPool` override that binds the connection to the pre-validated address.

A simpler short-term mitigation: re-run `validate_image_url` immediately before each fetch (already done for `/associate` pre-validation) AND validate the final response's `X-Forwarded-For` / remote address. This does not fully close the window but narrows it.

## Agent Assignment

python-agent (security-agent to review the implementation)

## Definition of Done

- [ ] Custom httpx transport or equivalent that reuses the pre-validated IP for the actual HTTP fetch
- [ ] DNS rebinding TOCTOU comment updated to reflect resolution status
- [ ] Test added for DNS rebinding scenario (mock DNS that returns different IPs on successive calls)
