import { test, expect } from "@playwright/test";

const DEV_EMAIL = "owner@thestacks.app";
const DEV_PASSWORD = "dev-password-123";

async function signIn(page: import("@playwright/test").Page) {
  await page.goto("/login");
  await page.fill('input[id="email"]', DEV_EMAIL);
  await page.fill('input[id="password"]', DEV_PASSWORD);
  await page.click("button.login-card__submit");
  await page.waitForURL("**/antilibrary", { timeout: 15000 });
}

test.describe("Navbar navigation — authenticated", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page);
  });

  const navItems = [
    { label: "Library", path: "/library", href: "/library" },
    { label: "Antilibrary", path: "/antilibrary", href: "/antilibrary" },
    { label: "Wish List", path: "/wishlist", href: "/wishlist" },
    { label: "Reading Pile", path: "/reading-pile", href: "/reading-pile" },
    { label: "Looking for a Home", path: "/looking-for-home", href: "/looking-for-home" },
    { label: "Catalogue", path: "/catalogue", href: "/catalogue" },
    { label: "Search", path: "/search", href: "/search" },
    { label: "Add Book", path: "/upload", href: "/upload" },
    { label: "Settings", path: "/settings/consent", href: "/settings/consent" },
  ];

  for (const item of navItems) {
    test(`clicking "${item.label}" navigates to ${item.path}`, async ({ page }) => {
      // Use href to uniquely identify the link (avoids "Library" matching "Antilibrary")
      const navLink = page.locator(`a.app-nav__link[href="${item.href}"]`);
      await expect(navLink).toBeVisible({ timeout: 5000 });

      // Force click to bypass any overlapping elements (diagnoses vs blocks)
      await navLink.click();

      // Verify URL changed
      await expect(page).toHaveURL(new RegExp(item.path.replace(/\//g, "\\/")), {
        timeout: 10000,
      });

      // Verify we're still authenticated
      await expect(page.locator(".app-nav__user")).toBeVisible();
    });
  }

  test("navigating between all shelves preserves auth state", async ({ page }) => {
    const shelves = [
      { href: "/library", label: "Library" },
      { href: "/antilibrary", label: "Antilibrary" },
      { href: "/wishlist", label: "Wish List" },
      { href: "/reading-pile", label: "Reading Pile" },
      { href: "/looking-for-home", label: "Looking for a Home" },
    ];

    for (const shelf of shelves) {
      await page.locator(`a.app-nav__link[href="${shelf.href}"]`).click();
      await page.waitForTimeout(500);
      await expect(page.locator(".app-nav__user")).toBeVisible();
    }

    // Sign In link should NOT be visible when authenticated
    await expect(page.locator('a.app-nav__link[href="/login"]')).not.toBeVisible();
  });
});

test.describe("Navbar navigation — unauthenticated", () => {
  test("only Costs and Sign In are visible", async ({ page }) => {
    await page.goto("/login");

    const navLinks = page.locator(".app-nav__link");
    const texts = await navLinks.allTextContents();

    expect(texts).toContain("Costs");
    expect(texts).toContain("Sign In");
    expect(texts).not.toContain("Library");
    expect(texts).not.toContain("Add Book");
    expect(texts).not.toContain("Search");
  });
});
