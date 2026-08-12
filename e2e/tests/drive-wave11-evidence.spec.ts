/**
 * Wave 11 live-drive evidence capture (11b import + 11c syndication).
 * Not a test — a scripted drive that screenshots each surface on the preview.
 * Run: BASE_URL=https://<preview>.fly.dev npx playwright test drive-wave11-evidence.ts --project=chromium
 */
import { test, expect } from "@playwright/test";

/**
 * Evidence drives are NOT regression tests: they screenshot surfaces and (for
 * 11e) depend on a row hand-seeded into one specific preview DB. A fresh CI
 * stack has neither, so the whole file stands down unless explicitly invoked
 * with DRIVE_EVIDENCE=1 — its first full-suite run failed exactly this way.
 */
test.skip(
  process.env.DRIVE_EVIDENCE !== "1",
  "evidence drive — run explicitly with DRIVE_EVIDENCE=1",
);
import * as path from "path";
import { mintSession, injectSession, uniqueEmail, type MintedSession } from "./helpers";
import type { Page } from "@playwright/test";

const SHOTS = "/private/tmp/claude-501/-Users-erinversfeld-thestacks/fa3ba5e9-76bc-4061-a253-9270334e733f/scratchpad/shots";
const FIXTURE = path.join(__dirname, "..", "fixtures", "goodreads_library_export.csv");

async function landOn(page: Page, session: MintedSession, pathName: string) {
  await injectSession(page, session);
  await page.goto(pathName);
  const overlay = page.getByTestId("onboarding-overlay");
  const appeared = await overlay
    .waitFor({ state: "visible", timeout: 3000 })
    .then(() => true)
    .catch(() => false);
  if (appeared) {
    await overlay.getByTestId("onboarding-skip-btn").click();
    await expect(overlay).not.toBeVisible();
  }
}

test("drive 11b: import journey with screenshots", async ({ page, request }) => {
  const session = await mintSession(request, { email: uniqueEmail("evidence-import") });
  test.skip(session === null, "helper off");
  if (!session) return;

  await landOn(page, session, "/import");
  await expect(page.getByTestId("import-page")).toBeVisible();
  await page.screenshot({ path: `${SHOTS}/11b-1-chooser.png`, fullPage: true });

  const chooserPromise = page.waitForEvent("filechooser");
  await page.getByTestId("import-choose-file").click();
  (await chooserPromise).setFiles(FIXTURE);

  const progress = page.getByTestId("import-progress");
  const sawProgress = await progress
    .waitFor({ state: "visible", timeout: 8000 })
    .then(() => true)
    .catch(() => false);
  if (sawProgress) {
    await page.screenshot({ path: `${SHOTS}/11b-2-progress.png`, fullPage: true });
  }

  await expect(page.getByTestId("import-report")).toBeVisible({ timeout: 90_000 });
  await page.screenshot({ path: `${SHOTS}/11b-3-report.png`, fullPage: true });

  await page.goto("/library");
  await expect(page.locator("body")).toContainText(/[Nn]ineteen [Ee]ighty|1984/, {
    timeout: 15_000,
  });
  await page.screenshot({ path: `${SHOTS}/11b-4-library.png`, fullPage: true });
});

test("drive 11c: syndication panel with screenshots", async ({ page, request, context }) => {
  const session = await mintSession(request, { email: uniqueEmail("evidence-posse") });
  test.skip(session === null, "helper off");
  if (!session) return;

  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  const auth = { Authorization: `Bearer ${session.token}` };
  await request.put("/api/settings/profile_visibility", {
    headers: auth,
    data: { profile_visibility: "public" },
  });
  const created = await request.post("/api/blog/posts", {
    headers: auth,
    data: {
      title: "The Evidence Post",
      body: "Written to be syndicated.",
      visibility: "public",
    },
  });
  const postId = (await created.json()).post.id as string;
  await request.post(`/api/blog/posts/${postId}/publish`, { headers: auth });

  await landOn(page, session, `/blog/${postId}`);
  await expect(page.getByTestId("syndication-panel")).toBeVisible();
  await page.getByTestId("syndication-panel").scrollIntoViewIfNeeded();
  await page.screenshot({ path: `${SHOTS}/11c-1-panel.png`, fullPage: true });

  await page.getByTestId("syndication-export-markdown").click();
  await expect(page.getByTestId("syndication-panel")).toContainText("Copied");
  const input = page.getByTestId("syndication-also-at-input");
  await input.fill("https://erin.substack.com/p/the-evidence-post");
  await input.press("Enter");
  await expect(page.getByTestId("syndication-backlink")).toBeVisible();
  await page.screenshot({ path: `${SHOTS}/11c-2-loop-closed.png`, fullPage: true });

  const me = await request.get("/api/auth/me", { headers: auth });
  const handle = (await me.json()).user.handle as string;
  await page.goto(`/api/feeds/u/${handle}/blog`);
  await page.screenshot({ path: `${SHOTS}/11c-3-feed.png` });
});

test("drive 11e: author card shows live bookstore events", async ({ page, request }) => {
  const session = await mintSession(request, { email: uniqueEmail("evidence-events") });
  test.skip(session === null, "helper off");
  if (!session) return;

  await request.put("/api/test/age-verification", {
    data: { email: session.email, verified: true },
  });

  await landOn(page, session, "/books/a1b2c3d4-0000-0000-0000-000000001037");
  const events = page.getByTestId("author-events");
  await events.scrollIntoViewIfNeeded();
  await expect(events).toBeVisible({ timeout: 15_000 });
  await expect(events).toContainText("An evening with Umberto Eco");
  await page.screenshot({ path: `${SHOTS}/11e-1-author-events.png`, fullPage: true });
});
