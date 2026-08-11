import type { FullConfig } from "@playwright/test";

/**
 * Playwright globalSetup — warm the deployed preview before any project runs.
 *
 * the preview core app runs with auto_stop_machines = true and can
 * go cold between the deploy warmup and the `setup` project's first login,
 * yielding an HTTP 502 that fails the whole E2E gate. When BASE_URL points at a
 * remote deployment we poll its health endpoint until it returns 200 before any
 * test project starts. This mirrors the shell-side warm_remote_preview guard in
 * scripts/test-e2e.sh so the app is warm whichever entrypoint launched the run.
 *
 * REAL WALL-CLOCK BOUND: a cold Fly machine rejects fast (connection-refused /
 * instant 502), so each fetch returns in milliseconds. We therefore AWAIT a
 * fixed interval between attempts — otherwise all attempts would burn through in
 * <1s and the machine would get no time to wake. The effective warmup window is
 * attempts × interval (default 20 × 3s ≈ 60s), matching wait_for_health's
 * date-deadline behaviour on the shell side.
 *
 * Both bounds are env-overridable so the behavioural test can drive the real
 * loop instantly (small attempt count, zero interval):
 *   PREVIEW_WARMUP_ATTEMPTS      (default 20)
 *   PREVIEW_WARMUP_INTERVAL_MS   (default 3000)
 *
 * When BASE_URL is unset (local `npm test`) this is a strict no-op — no poll, no
 * throw — so local runs are entirely untouched.
 */

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

function positiveIntEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === "") {
    return fallback;
  }
  const parsed = Number(raw);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

async function globalSetup(_config: FullConfig): Promise<void> {
  const baseUrl = process.env.BASE_URL;

  if (!baseUrl) {
    return;
  }

  const healthUrl = `${baseUrl}/api/health`;
  const maxAttempts = positiveIntEnv("PREVIEW_WARMUP_ATTEMPTS", 20);
  const intervalMs = positiveIntEnv("PREVIEW_WARMUP_INTERVAL_MS", 3000);
  const perAttemptTimeoutMs = 3000;

  console.log(
    `==> globalSetup: warming ${healthUrl} before setup ` +
      `(${maxAttempts} attempts × ${intervalMs}ms)...`
  );

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      const resp = await fetch(healthUrl, {
        signal: AbortSignal.timeout(perAttemptTimeoutMs),
      });
      if (resp.status === 200) {
        console.log(`  Preview healthy at ${healthUrl} (attempt ${attempt})`);
        return;
      }
    } catch {
      // Cold start / connection refused / abort — swallow and retry until bound.
    }

    if (attempt < maxAttempts) {
      await sleep(intervalMs);
    }
  }

  throw new Error(
    `globalSetup: ${healthUrl} did not become healthy after ${maxAttempts} attempts ` +
      `(~${(maxAttempts * intervalMs) / 1000}s). The preview app never returned ` +
      `HTTP 200 — aborting E2E before the setup project to avoid a misleading 502 failure.`
  );
}

export default globalSetup;
