# Runbook: Production Data Access

This runbook covers all legitimate paths for accessing production data and the strict
policies that prohibit direct database access.

---

## 1. Accessing Admin Data (Break-Glass MFA Flow)

All production data access goes through the admin API. There is no other sanctioned path.

### Step 1 — Log in as owner

```
POST /api/admin/auth/login
Content-Type: application/json

{
  "email": "<owner-email>",
  "password": "<owner-password>"
}
```

Response includes a `session_id` (short-lived, MFA not yet verified).

### Step 2 — Verify MFA

```
POST /api/admin/auth/verify_mfa
Content-Type: application/json

{
  "session_id": "<session-id-from-step-1>",
  "totp_code": "<6-digit-TOTP-code>"
}
```

(Substitute `"recovery_code": "<recovery-code>"` for `totp_code` if using a one-time recovery code instead.)

Response includes a `token` with `typ: "admin_session"` and a 30-minute TTL.

### Step 3 — Use the Admin JWT

Include the token in all subsequent requests:

```
Authorization: Bearer <admin_session_token>
```

Available endpoints (all admin-authenticated; data endpoints under `/api/admin`, metrics dashboard under `/api`):

| Endpoint | Purpose |
|---|---|
| `GET /api/admin/users/by_email?email=` | Look up a user by email |
| `GET /api/admin/users/by_id?id=` | Look up a user by UUID |
| `GET /api/admin/audit_log?user_id=&from=&to=` | View audit events for a user |
| `GET /api/admin/platform_stats` | Platform-wide aggregate stats |
| `GET /api/admin/gdpr_export?user_id=` | Export all data for a user |
| `POST /api/admin/gdpr_erase` | Erase a user (requires `reason`) |
| `GET /api/metrics` | Admin metrics dashboard |
| `GET /api/metrics/quality-trends` | Data quality trend sparklines |
| `GET /api/metrics/source-health` | Per-source health status |
| `GET /api/metrics/enrichment-gaps` | Enrichment gap counts |
| `GET /api/admin/sources` | List discovered sources |
| `PUT /api/admin/sources/:id/approve` | Approve a source |
| `PUT /api/admin/sources/:id/reject` | Reject a source |
| `GET /api/admin/partners` | List partner applications |
| `PUT /api/admin/partners/:id/approve` | Approve a partner |
| `PUT /api/admin/partners/:id/reject` | Reject a partner |

### Step 4 — Log out

```
DELETE /api/admin/auth/logout
Authorization: Bearer <admin_session_token>
```

This revokes the session immediately. Sessions also expire after 30 minutes of inactivity.

---

## 2. Access Policy — Prohibited Methods

The following are **absolutely prohibited**. There are no exceptions, even in incidents.

| Method | Why prohibited |
|---|---|
| Direct `psql` to the Neon production database | Bypasses audit log; changes are untracked |
| SQL execution via the Neon console query runner | Same as above; console SQL leaves no application-level audit trail |
| `fly ssh console` to a running Core instance | No audit trail; allows arbitrary code execution |
| MCP SQL tools (e.g. `mcp__Neon__run_sql`) | Bypasses the application entirely; not audited |
| Sharing or exporting admin JWT tokens | Tokens are single-operator, non-transferable |

If a legitimate need arises that cannot be satisfied by the admin API, open an issue to
extend the API rather than resorting to direct access.

---

## 3. Configuring the Neon IP Allowlist

Restricting database connections to known IP ranges prevents direct connection attempts
even if credentials are leaked.

**Steps in the Neon console:**

1. Go to [console.neon.tech](https://console.neon.tech) and select the The Stacks project.
2. Click **Settings** in the left sidebar.
3. Click **IP Allow** (under the Security section).
4. Enable **IP Allow** if not already active.
5. Add each allowed CIDR block or IP address:
   - Fly.io outbound IP ranges for the `iad` (Washington DC) region. Retrieve the current
     list from `https://fly.io/docs/reference/public-ips/` — Fly.io IPs change periodically,
     so check this list before adding or removing entries.
   - Your organisation's office/VPN egress IP(s) for emergency operator access.
   - CI runner IPs if your CI provider uses static IPs (GitHub Actions uses dynamic IPs;
     use a NAT gateway or Fly.io proxy for CI database access instead).
6. Click **Save**.
7. Verify connectivity: call the health endpoint from a machine on the allowlist:
   ```
   curl https://<your-fly-app>.fly.dev/api/health
   ```
   This goes through Fly.io, exercises the database connection, and does not require `fly ssh console`.
8. Verify that a direct connection from an unlisted IP is rejected (e.g., from a laptop not on the allowlist, attempt `psql <DATABASE_URL>` and confirm it is refused).

**Important:** After adding a new Fly.io machine or region, re-check the IP allowlist.
Fly.io may assign a new outbound IP that is not yet in the allowlist.

---

## 4. Scoping the NEON_API_KEY to Branch Management Only

The `NEON_API_KEY` secret stored in Fly.io is used by the deploy pipeline to create and
delete Neon branches for preview deployments. It must NOT have permission to execute SQL.

**Steps in the Neon console:**

1. Go to [console.neon.tech](https://console.neon.tech) → **Account** → **API Keys**.
2. If an existing key is used for deploy pipelines, delete it and create a new one with
   a restricted scope.
3. Click **Generate new API key**.
4. Name it `stacks-deploy-pipeline` (or similar).
5. Under **Permissions**, select only:
   - `branches:read`
   - `branches:write` (create/delete branches)
   - `projects:read`
   - Do NOT select `sql:execute`, `databases:write`, `roles:write`, or project-level
     admin permissions.
6. Copy the key and update it in Fly.io:
   ```
   fly secrets set NEON_API_KEY=<new-key> --app stacks-core
   fly secrets set NEON_API_KEY=<new-key> --app stacks-vision
   ```
7. Rotate the old key by deleting it from the Neon console API Keys page.
8. Confirm the deploy pipeline still works by triggering a preview deployment.

**Note:** If Neon's console does not yet support fine-grained API key scopes (the feature
is in beta as of 2026), use a project-scoped key (restricted to The Stacks project only)
as the minimum available restriction, and document the gap in the security issue tracker.

---

## 5. Expected Audit Trail by Access Type

Every action through the admin API is recorded. Here is what to expect:

| Action | Audit record |
|---|---|
| Any `GET /api/admin/*` request | `action: "admin.call"`, `endpoint`, `operator_session_id`, `success: true/false`, `occurred_at` written to `audit.audit_log` |
| Any `POST /api/admin/gdpr_erase` | Same as above plus `reason` in `metadata` |
| Admin login | `action: "admin.login"` in `audit.audit_log` |
| Admin MFA verification | `action: "admin.mfa_verified"` in `audit.audit_log` |
| Admin logout | `action: "admin.logout"` in `audit.audit_log` |
| Neon branch create/delete | Logged in Neon console audit log (not in application `audit_log`) |
| Direct psql / Neon console SQL | NOT logged in application audit trail — this is why it is prohibited |

To query the audit log for a session:

```
GET /api/admin/audit_log?user_id=<operator-user-id>&from=<ISO8601>&to=<ISO8601>
Authorization: Bearer <admin_session_token>
```

---

## 6. Incident Response — Unauthorized Access Detected

If you detect or suspect unauthorized production data access:

### Immediate containment

1. **Revoke all active admin sessions:**
   Run from an authenticated admin session:
   ```
   # There is no bulk-revoke endpoint yet — revoke your own session and rotate secrets.
   DELETE /api/admin/auth/logout
   ```
   Then rotate `SECRET_KEY_BASE` and `CLOAK_KEY` in Fly.io secrets to invalidate all
   existing Guardian tokens and Cloak-encrypted fields:
   ```
   fly secrets set SECRET_KEY_BASE=$(mix phx.gen.secret) --app stacks-core
   fly secrets set CLOAK_KEY=$(mix phx.gen.secret 32) --app stacks-core
   ```
   Fly.io will restart the app and issue new secrets, invalidating all existing JWTs.

2. **Rotate NEON_API_KEY** (see Section 4) if the key may have been compromised.

3. **Enable Neon IP allowlist** immediately if not already active (see Section 3), or
   narrow it to remove any suspicious IPs.

### Investigation

4. Query the audit log for the suspected time window:
   ```
   GET /api/admin/audit_log?user_id=<suspect-user-id>&from=<ISO8601>&to=<ISO8601>
   ```

5. Check the Neon console audit log for any direct SQL connections during the window.

6. Check Fly.io access logs:
   ```
   fly logs --app stacks-core | grep "admin"
   ```

### Recovery and notification

7. If personal data was accessed, assess GDPR notification obligations (72-hour window
   from discovery under GDPR Article 33).

8. Document the incident in `issues/` with timeline, scope of access, and remediation
   steps taken.

9. After containment, conduct a post-mortem and update this runbook with any gaps found.
