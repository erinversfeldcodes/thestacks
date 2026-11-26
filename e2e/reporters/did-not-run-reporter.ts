import type {
  Reporter,
  FullConfig,
  Suite,
  TestCase,
  FullResult,
} from "@playwright/test/reporter";

// ⛔ NAMES the cases a failed dependency removed from the run, instead of letting
// them vanish into Playwright's bare "N did not run" tally. When `chromium` goes
// red the `upload` and `ratelimit` projects that depend on it are never
// executed, so the suite's coverage silently contracts exactly when something is
// already wrong — and a count cannot tell you WHICH cases stopped being checked.
export default class DidNotRunReporter implements Reporter {
  private suite!: Suite;
  private deps = new Map<string, string[]>();

  onBegin(config: FullConfig, suite: Suite): void {
    this.suite = suite;
    for (const p of config.projects) this.deps.set(p.name, p.dependencies ?? []);
  }

  private projectOf(t: TestCase): string {
    // titlePath() is ['', <project>, <file>, ...<describe>, <title>].
    return t.titlePath()[1] ?? "";
  }

  private blocked(name: string, failed: Set<string>, seen = new Set<string>()): boolean {
    for (const d of this.deps.get(name) ?? []) {
      if (seen.has(d)) continue;
      seen.add(d);
      if (failed.has(d) || this.blocked(d, failed, seen)) return true;
    }
    return false;
  }

  onEnd(_result: FullResult): void {
    const tests = this.suite.allTests();
    // A project "failed" if any of its tests ended unexpected — which is what
    // makes Playwright refuse everything downstream of it.
    const failed = new Set<string>();
    for (const t of tests) {
      if (t.outcome() === "unexpected") failed.add(this.projectOf(t));
    }
    // DID NOT RUN = never executed (no results) BECAUSE its project sits
    // downstream of a failure. The dependency clause is what distinguishes this
    // from an intentional `test.skip()`, which also has no results but whose
    // project lost no dependency.
    const didNotRun = tests.filter(
      (t) => t.results.length === 0 && this.blocked(this.projectOf(t), failed),
    );
    if (didNotRun.length === 0) return;
    process.stderr.write(
      `\n${didNotRun.length} E2E case(s) DID NOT RUN — a dependency project failed, so these were never executed. ` +
        `This is LOST COVERAGE, named rather than hidden behind a bare "did not run" count:\n`,
    );
    for (const t of didNotRun) {
      process.stderr.write(`  ✗ not-run: ${t.titlePath().filter(Boolean).join(" › ")}\n`);
    }
    process.stderr.write(
      `A green run that skipped these proved nothing about them.\n\n`,
    );
  }
}
