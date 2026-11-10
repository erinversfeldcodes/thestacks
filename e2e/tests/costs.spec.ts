import { test, expect } from "./fixtures";

test.describe("Cost Transparency", () => {
  test("page loads without authentication and shows cost breakdown", async ({
    page,
  }) => {
    await page.goto("/costs");

    await expect(page.locator(".costs__title")).toHaveText(
      "Cost Transparency"
    );
    await expect(page.locator(".costs__subtitle")).toContainText(
      "honest look"
    );

    await expect(page.getByTestId('costs-content')).toBeVisible({
      timeout: 10_000,
    });

    await expect(page.locator(".costs__banner-amount")).toBeVisible();
    await expect(page.locator(".costs__banner-amount")).toContainText("$");

    await expect(
      page.getByTestId('costs-category-card').first()
    ).toBeVisible();

    await expect(page.locator(".costs__story-card")).toHaveCount(3);
    await expect(
      page.locator(".costs__story-card").first()
    ).toContainText("$");

    // ⛔ THE PAGE NO LONGER CLAIMS "EVERY NUMBER ON THIS PAGE IS REAL", and
    // this assertion used to require that it did. The sentence was false in two
    // directions: most lines are a published price times an observed quantity
    // (honest arithmetic, but an estimate of spend), and five cost-item
    // builders answered an unavailable measurement with zero — so the page
    // rendered "$0.00" for services it had no measurement of, directly above
    // that claim.
    await expect(page.locator(".costs__philosophy-text")).toContainText(
      "Each line above says how its figure was arrived at"
    );
  });

  test("every cost line declares how its figure was arrived at", async ({
    request,
  }) => {
    const resp = await request.get("/api/costs");
    expect(resp.status()).toBe(200);
    const body = await resp.json();

    const items = body.data.categories.flatMap(
      (c: { items: unknown[] }) => c.items
    );

    // ⬛ ANTI-VACUITY FIRST. A deployed stack with no cost rows would make every
    // assertion below pass over an empty list — which is the shape this
    // project's own notes call out as a guard that cannot fail.
    expect(items.length).toBeGreaterThan(0);

    const known = ["measured", "rate_card", "absent"];

    for (const item of items as Array<{ service: string; basis: string }>) {
      expect(known, `${item.service} declares an unknown basis`).toContain(
        item.basis
      );
    }
  });

  // ⛔ A LINE WITH NO FIGURE MUST NOT RENDER AS MONEY. This is the whole point
  // of the basis field: a reader seeing "$0.00" concludes the service is free,
  // and five builders used to produce exactly that for an unmeasured metric.
  //
  // ⚠️ THE PRECONDITION IS SKIPPED VISIBLY, NOT GUARDED SILENTLY. My first
  // version wrapped the assertion in `if (text.includes("not yet measured"))`,
  // which on a stack where every meter happens to be populated is a loop that
  // asserts nothing and reports green — the "guard that makes a test unable to
  // fail" shape this repo already tracks sixteen of. A silent pass and a real
  // pass are indistinguishable, and that is worse than a skip.
  //
  // ⚖️ So the absent line is located through the API first. No absent line
  // means the precondition is absent, which `test.skip` says out loud and
  // `E2E_EXPECT_ABSENT_COST_LINE=1` can turn into a hard failure where one is
  // guaranteed — the same pattern the Modal-dependent specs use.
  test("an absent line shows text, not a currency zero", async ({
    page,
    request,
  }) => {
    const resp = await request.get("/api/costs");
    expect(resp.status()).toBe(200);
    const body = await resp.json();

    const absent = body.data.categories
      .flatMap((c: { items: Array<{ service: string; basis: string }> }) =>
        c.items
      )
      .filter((i: { basis: string }) => i.basis === "absent");

    if (absent.length === 0) {
      // ⚖️ Asserts the PRECONDITION and names the flag in the failure text, the
      // shape the sibling helpers use. The inverted form asserted `required`
      // was false, so its message — advising the reader to set the flag — only
      // ever printed when the flag was already set.
      expect(
        process.env.E2E_EXPECT_ABSENT_COST_LINE !== "1",
        "E2E_EXPECT_ABSENT_COST_LINE=1 but no cost line has basis=absent on " +
          "this stack, so the no-currency-zero rendering is unexercised"
      ).toBe(true);
      test.skip(true, "no absent cost line on this stack to render");
      return;
    }

    await page.goto("/costs");
    await expect(page.locator(".costs__philosophy-text")).toBeVisible({
      timeout: 15000,
    });

    const texts = await page
      .locator(".costs__service-amount")
      .allInnerTexts();

    const absentRendered = texts.filter((t) =>
      t.includes("not yet measured")
    );

    // ⬛ The API said there is an absent line, so the page must show one. If
    // this is empty the page is rendering a figure for it — which is the defect.
    // ⛔ COUNT-COUPLED, NOT `>= 1`. This asserted `toBeGreaterThan(0)` while its
    // own message claimed a fact about `absent.length` — so with 5 absent lines
    // and 4 still rendering `$0.00` it passed and printed a message that was
    // false. The original defect was FIVE builders answering an unavailable
    // measurement with zero, so a partial regression is the realistic shape,
    // and it is exactly what `>= 1` cannot see.
    expect(
      absentRendered.length,
      `the API reports ${absent.length} absent line(s) and the page renders ${absentRendered.length} as text`
    ).toBe(absent.length);

    for (const t of absentRendered) {
      expect(t).not.toMatch(/\$/);
    }
  });

  test("API endpoint returns cost data without auth", async ({ request }) => {
    const resp = await request.get("/api/costs");
    expect(resp.status()).toBe(200);
    const body = await resp.json();
    expect(body).toHaveProperty("data");
    expect(body.data).toHaveProperty("categories");
    expect(Array.isArray(body.data.categories)).toBe(true);
  });
});

test.describe("Cost Transparency — reachable via UI (logged out)", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test("About → /costs via the costs link", async ({ page }) => {
    await page.goto("/about");

    const costsLink = page.getByTestId("about-costs-link");
    await expect(costsLink).toBeVisible({ timeout: 10_000 });
    await costsLink.click();

    await expect(page).toHaveURL((url) => url.pathname === "/costs");
    await expect(page.getByTestId("costs-content")).toBeVisible({
      timeout: 10_000,
    });
    await expect(page.locator(".costs__title")).toHaveText("Cost Transparency");
  });

  test("home → About → /costs (full click-path from the landing page)", async ({
    page,
  }) => {
    await page.goto("/");

    const aboutLink = page.locator('.page--home a[href="/about"]');
    await expect(aboutLink).toBeVisible({ timeout: 10_000 });
    await aboutLink.click();
    await expect(page).toHaveURL((url) => url.pathname === "/about");

    const costsLink = page.getByTestId("about-costs-link");
    await expect(costsLink).toBeVisible({ timeout: 10_000 });
    await costsLink.click();
    await expect(page).toHaveURL((url) => url.pathname === "/costs");
    await expect(page.getByTestId("costs-content")).toBeVisible({
      timeout: 10_000,
    });
  });
});
