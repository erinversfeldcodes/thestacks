# Issue #010: Harmonise HMAC Service-to-Service Auth Between Elixir Core and Python Vision Sidecar

## Summary

The Elixir core and Python vision sidecar use incompatible HMAC authentication schemes. Every real (non-mock) call from `IdentifyBookJob` to the sidecar returns HTTP 401. This must be fixed before Issue #009 (bulk upload) can ship, and before any production deployment.

## Problem

Two mismatches exist between `apps/core/lib/stacks/ai/client.ex` and `apps/vision/app/services/hmac_auth.py`:

### 1. Header name

| Side | Header |
|------|--------|
| Elixir sends | `x-stacks-signature` |
| Python expects | `X-Internal-Token` |

### 2. Message format / signing scheme

| Side | What is signed |
|------|---------------|
| Elixir signs | Raw JSON request body (`HMAC-SHA256(secret, body)`) |
| Python expects | `"<timestamp>.<METHOD>.<path>"` string (with replay-protection window of ±60 s) |

The two schemes produce different byte sequences, so even if the header name were corrected the signature would never verify.

## Decision Required

Choose one canonical scheme. Recommended option (adopt the Python scheme, it is more secure):

**Elixir must send `X-Internal-Token: <timestamp>.<HMAC-SHA256(secret, "<ts>.<METHOD>.<path>")>`**

- Timestamp replay protection prevents token reuse (important when images can contain sensitive ISBN data).
- Body-HMAC is simpler but cannot prevent replay attacks.

Alternative: adopt the simpler body-HMAC on both sides (modify Python to match Elixir). Faster to implement but weaker security.

## Files to Change

### Option A — adopt Python scheme (recommended)

**`apps/core/lib/stacks/ai/client.ex`**

Replace `hmac_signature/1` and the header sent in `make_vision_request/2`:

```elixir
defp auth_token(method, path) do
  ts = System.os_time(:second) |> to_string()
  secret = Application.get_env(:core, :vision_hmac_secret, "")
  message = "#{ts}.#{method}.#{path}"
  sig = :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode16(case: :lower)
  "#{ts}.#{sig}"
end

# In make_vision_request/2:
# Replace: {"x-stacks-signature", hmac_signature(body)}
# With:    {"X-Internal-Token", auth_token("POST", "/#{endpoint_path(endpoint)}")}
```

No changes needed to `hmac_auth.py` or its tests.

### Option B — adopt Elixir scheme

**`apps/vision/app/services/hmac_auth.py`**

Change `_TOKEN_HEADER` to `"x-stacks-signature"` and simplify `verify_hmac` to verify `HMAC-SHA256(secret, body)` from the raw request body. Remove timestamp/replay logic.

Update `apps/vision/tests/test_auth.py` accordingly.

## Acceptance Criteria

- [ ] A real (non-mock) `IdentifyBookJob` run reaches the sidecar and gets HTTP 200 (not 401).
- [ ] `just test-elixir` passes.
- [ ] `just test-python` passes.
- [ ] `just lint-elixir` (Sobelow) passes.
- [ ] Header name and signing scheme are documented in `docs/technical-architecture.md` section on internal service auth.

## Blocks

- Issue #009 (bulk upload) — the job worker calls the sidecar directly; 401s will silently cancel all jobs.
- Issue #004 (production deployment) — sidecar will reject all traffic in staging/prod.

## Priority

**High** — the platform's core feature (book identification) is silently broken in all non-test environments.
