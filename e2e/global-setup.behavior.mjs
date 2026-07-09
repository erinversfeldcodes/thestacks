// e2e/global-setup.behavior.mjs
//
// Behavioural test for Guard B (Issue #175) — the Playwright globalSetup warmup.
//
// The static grep test (test/platform/e2e_global_setup_guard_test.sh) only
// proves wiring; it cannot catch logic bugs (inverted guard, wrong URL, a loop
// that never actually waits). This test EXECUTES the real default export with a
// stubbed global fetch so it runs offline and instantly, and asserts behaviour.
//
// e2e/package.json is `type: commonjs`, which would force node to parse the
// .ts as CommonJS and choke on `export default`. We instead strip the TS types
// with node's built-in stripper and import the result as an ES module via a
// data: URL — this uses node's OWN type-stripping (same as Playwright's loader
// path) with no extra dependencies.

import { stripTypeScriptTypes } from "node:module";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TS_PATH = path.join(__dirname, "global-setup.ts");

// ── tiny assert harness ──────────────────────────────────────────────────────
let passed = 0;
let failed = 0;
const failures = [];

function ok(cond, msg) {
  if (cond) {
    passed++;
    console.log(`ok   ${msg}`);
  } else {
    failed++;
    failures.push(msg);
    console.log(`FAIL ${msg}`);
  }
}

// ── load the module under test as ESM (strip types → data: URL) ──────────────
async function loadGlobalSetup() {
  const src = readFileSync(TS_PATH, "utf8");
  const js = stripTypeScriptTypes(src, { mode: "strip" });
  const url = "data:text/javascript;base64," + Buffer.from(js).toString("base64");
  const mod = await import(url);
  return mod.default;
}

// ── fetch stub factory ───────────────────────────────────────────────────────
// mode: "ok" → returns {status:200}; "bad" → {status:502}; "throw" → rejects.
function installFetchStub(mode) {
  const calls = [];
  globalThis.fetch = async (input) => {
    calls.push(String(input));
    if (mode === "throw") {
      throw new Error("ECONNREFUSED (stubbed cold machine)");
    }
    return { status: mode === "ok" ? 200 : 502 };
  };
  return calls;
}

function clearEnv() {
  delete process.env.BASE_URL;
  delete process.env.PREVIEW_WARMUP_ATTEMPTS;
  delete process.env.PREVIEW_WARMUP_INTERVAL_MS;
}

async function main() {
  const globalSetup = await loadGlobalSetup();
  const realFetch = globalThis.fetch;

  // ── Case (a): BASE_URL unset → no-op, NEVER calls fetch ────────────────────
  {
    clearEnv();
    const calls = installFetchStub("ok");
    let threw = false;
    const start = Date.now();
    try {
      await globalSetup({});
    } catch {
      threw = true;
    }
    const elapsed = Date.now() - start;
    ok(!threw, "(a) local mode (BASE_URL unset) resolves without throwing");
    ok(calls.length === 0, `(a) local mode makes zero fetch calls (got ${calls.length})`);
    ok(elapsed < 500, `(a) local mode returns immediately (${elapsed}ms)`);
  }

  // ── Case (b): fetch → 200 → resolves after ≥1 fetch, URL ends /api/health ──
  {
    clearEnv();
    process.env.BASE_URL = "https://preview-175.example.test";
    process.env.PREVIEW_WARMUP_ATTEMPTS = "5";
    process.env.PREVIEW_WARMUP_INTERVAL_MS = "0";
    const calls = installFetchStub("ok");
    let threw = false;
    try {
      await globalSetup({});
    } catch {
      threw = true;
    }
    ok(!threw, "(b) healthy preview resolves without throwing");
    ok(calls.length >= 1, `(b) healthy preview polled at least once (got ${calls.length})`);
    ok(
      calls.length === 1,
      `(b) healthy preview stops polling after first 200 (got ${calls.length})`
    );
    ok(
      calls.length > 0 && calls[0].endsWith("/api/health"),
      `(b) polled URL ends with /api/health (got ${calls[0]})`
    );
  }

  // ── Case (c): fetch always fails → REJECTS, honours the attempt bound ──────
  // This is the timing-defect guard: with interval stubbed to 0 the loop must
  // still make EXACTLY the configured number of attempts before giving up.
  {
    clearEnv();
    process.env.BASE_URL = "https://preview-175.example.test";
    process.env.PREVIEW_WARMUP_ATTEMPTS = "3";
    process.env.PREVIEW_WARMUP_INTERVAL_MS = "0";
    const calls = installFetchStub("throw");
    let err = null;
    try {
      await globalSetup({});
    } catch (e) {
      err = e;
    }
    ok(err !== null, "(c) unhealthy preview rejects (throws)");
    ok(
      err !== null && /healthy/.test(err.message),
      "(c) error message mentions 'healthy'"
    );
    ok(
      err !== null && err.message.includes("https://preview-175.example.test"),
      "(c) error message names the preview URL"
    );
    ok(
      calls.length === 3,
      `(c) loop honours PREVIEW_WARMUP_ATTEMPTS: exactly 3 fetch calls (got ${calls.length})`
    );
  }

  // ── Case (c2): non-200 responses also exhaust the bound ────────────────────
  {
    clearEnv();
    process.env.BASE_URL = "https://preview-175.example.test";
    process.env.PREVIEW_WARMUP_ATTEMPTS = "4";
    process.env.PREVIEW_WARMUP_INTERVAL_MS = "0";
    const calls = installFetchStub("bad");
    let err = null;
    try {
      await globalSetup({});
    } catch (e) {
      err = e;
    }
    ok(err !== null, "(c2) persistent 502 rejects (throws)");
    ok(
      calls.length === 4,
      `(c2) 502 path honours the attempt bound: exactly 4 calls (got ${calls.length})`
    );
  }

  globalThis.fetch = realFetch;

  console.log(`\n# passed: ${passed}  failed: ${failed}`);
  if (failed > 0) {
    console.log("# failures:");
    for (const f of failures) console.log(`#   - ${f}`);
    process.exit(1);
  }
  process.exit(0);
}

main().catch((e) => {
  console.error("behaviour test crashed:", e);
  process.exit(2);
});
