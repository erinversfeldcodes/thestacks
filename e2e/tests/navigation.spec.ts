import { test, expect } from "@playwright/test";
import { suiteAuthFile } from "./helpers";

test.describe("Navbar navigation — authenticated", () => {
  test.use({ storageState: suiteAuthFile("navigation") });

  // Top-level nav items (visible as direct links)
  const topLevelItems = [
    { label: "Library", path: "/library", href: "/library" },
    { label: "Antilibrary", path: "/antilibrary", href: "/antilibrary" },
    { label: "Wish List", path: "/wishlist", href: "/wishlist" },
    { label: "Reading Pile", path: "/reading-pile", href: "/reading-pile" },
    { label: "Looking for a Home", path: "/looking-for-home", href: "/looking-for-home" },
    { label: "Catalogue", path: "/catalogue", href: "/catalogue" },
  ];

  // Dropdown items (nested inside dropdown menus, use app-nav__dropdown-link)
  const dropdownItems = [
    { label: "Search", path: "/search", href: "/search", parent: "Catalogue" },
    { label: "Add Book", path: "/upload", href: "/upload", parent: "Catalogue" },
    { label: "Settings", path: "/settings/profile", href: "/settings/profile", parent: null },
  ];

  for (const item of topLevelItems) {
    test(`clicking "${item.label}" navigates to ${item.path}`, async ({ page }) => {
      await page.goto("/antilibrary");
      await page.waitForSelector(".app-nav__link", { timeout: 10000 });

      const navLink = page.locator(`a.app-nav__link[href="${item.href}"]`);
      await expect(navLink).toBeVisible({ timeout: 5000 });

      await navLink.click();

      await expect(page).toHaveURL(new RegExp(item.path.replace(/\//g, "\\/")), {
        timeout: 10000,
      });

      await expect(page.locator(".app-nav__user")).toBeVisible();
    });
  }

  for (const item of dropdownItems) {
    test(`clicking "${item.label}" navigates to ${item.path}`, async ({ page }) => {
      await page.goto("/antilibrary");
      await page.waitForSelector(".app-nav__link", { timeout: 10000 });

      // Hover over the parent dropdown to reveal the dropdown menu
      if (item.parent) {
        const parentLink = page.locator(`a.app-nav__link:has-text("${item.parent}")`);
        await parentLink.hover();
      } else {
        // Settings is under the user name dropdown
        const userDropdown = page.locator(".app-nav__user");
        await userDropdown.hover();
      }

      const dropdownLink = page.locator(`a.app-nav__dropdown-link[href="${item.href}"]`);
      await expect(dropdownLink).toBeVisible({ timeout: 5000 });

      await dropdownLink.click();

      await expect(page).toHaveURL(new RegExp(item.path.replace(/\//g, "\\/")), {
        timeout: 10000,
      });

      await expect(page.locator(".app-nav__user")).toBeVisible();
    });
  }

  test("navigating between all shelves preserves auth state", async ({ page }) => {
    await page.goto("/antilibrary");
    await page.waitForSelector(".app-nav__link", { timeout: 10000 });

    const shelves = [
      { href: "/library", label: "Library" },
      { href: "/antilibrary", label: "Antilibrary" },
      { href: "/wishlist", label: "Wish List" },
      { href: "/reading-pile", label: "Reading Pile" },
      { href: "/looking-for-home", label: "Looking for a Home" },
    ];

    for (const shelf of shelves) {
      await page.locator(`a.app-nav__link[href="${shelf.href}"]`).click();
      await expect(page).toHaveURL(new RegExp(shelf.href.replace(/\//g, "\\/")), {
        timeout: 10000,
      });
      await expect(page.locator(".app-nav__user")).toBeVisible();
    }

    // Sign In link should NOT be visible when authenticated
    await expect(page.locator('a.app-nav__link[href="/login"]')).not.toBeVisible();
  });
});

test.describe("Navbar navigation — unauthenticated", () => {
  test("only Catalogue and Sign In are visible in nav, Costs under brand dropdown", async ({ page }) => {
    await page.goto("/login");

    const navLinks = page.locator(".app-nav__link");
    const texts = await navLinks.allTextContents();

    expect(texts).toContain("Catalogue");
    expect(texts).toContain("Sign In");
    expect(texts).not.toContain("Costs");
    expect(texts).not.toContain("Library");
    expect(texts).not.toContain("Add Book");
    expect(texts).not.toContain("Search");

    // Costs is under the brand dropdown
    const brand = page.locator(".app-header__brand");
    await brand.hover();
    await expect(page.locator('a.app-nav__dropdown-link[href="/costs"]')).toBeVisible({ timeout: 3000 });
  });
});
