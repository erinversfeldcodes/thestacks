import path from "path";
import { test, expect, Page } from "@playwright/test";
import { suiteAuthFile } from "./helpers";

const PIPELINE_TIMEOUT = 300_000;

test.use({ storageState: suiteAuthFile("upload") });

test.describe("Upload pipeline — barcode pre-pass", () => {
  test.skip(
    !!process.env.SKIP_VISION,
    "Modal vision disabled to save credit (SKIP_VISION). Re-enable by unsetting SKIP_VISION — required when changing apps/vision or the upload→vision code path."
  );

  test(
    "identifies The Name of the Rose from barcode_isbn_clean.jpg via local OCR",
    async ({ page }) => {
      test.setTimeout(390_000);

      await page.goto("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/barcode_isbn_clean.jpg")
      );

      await expect(page.getByTestId("upload-loading")).toContainText(
        "Reading your photo...",
        { timeout: 30_000 }
      );

      const bookResponsePromise = page.waitForResponse(
        (resp) =>
          /\/api\/books\/[^/?]+$/.test(resp.url()) && resp.status() === 200,
        { timeout: 240_000 }
      );

      const verify = page.getByTestId('upload-verify');
      const duplicate = page.getByText('Already in Your Library');
      await expect(verify.or(duplicate)).toBeVisible({ timeout: 240_000 });

      if (await verify.isVisible()) {
        const bookJson = await (await bookResponsePromise).json();
        const bookId: string = bookJson.book?.id ?? bookJson.id;
        const initialTitle: string =
          bookJson.book?.title ?? bookJson.title ?? "";

        if (/^ISBN \d{13}$/.test(initialTitle)) {
          await expect(page.locator(".upload-verify__title")).toContainText(
            initialTitle
          );

          await expect
            .poll(
              () =>
                page.evaluate(async (id) => {
                  const auth = JSON.parse(
                    localStorage.getItem("stacks-auth") || "{}"
                  );
                  const resp = await fetch(`/api/books/${id}`, {
                    headers: { Authorization: `Bearer ${auth.token}` },
                  });
                  if (!resp.ok) return "";
                  const data = await resp.json();
                  return (data.book?.title ?? "") as string;
                }, bookId),
              { timeout: 120_000, intervals: [2000, 3000, 5000] }
            )
            .toMatch(/Name of the Rose/i);
        } else {
          expect(initialTitle).toMatch(/Name of the Rose/i);
        }
      } else {
        await expect(page.getByText(/Name of the Rose/i)).toBeVisible();
      }
    }
  );
});

test.describe("Upload pipeline — non-book rejection", () => {
  test(
    "bunny image rejected as Doesn't Look Like a Book",
    async ({ page }) => {
      test.setTimeout(PIPELINE_TIMEOUT);

      await page.goto("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/not_a_book.jpg")
      );

      await expect(page.getByTestId("upload-loading")).toContainText(
        "Reading your photo...",
        { timeout: 30_000 }
      );

      await expect(page.getByTestId("upload-error")).toBeVisible({
        timeout: PIPELINE_TIMEOUT,
      });
      await expect(page.getByTestId("upload-error")).toContainText(
        "Doesn't Look Like a Book"
      );

      await expect(
        page.getByRole("button", { name: "Try Again" })
      ).toBeVisible();
    }
  );
});

test.describe("Upload pipeline — ISBN not found", () => {
  test(
    "nonexistent ISBN-13 with valid checksum is refused by the ISBN hard gate",
    async ({ page }) => {
      test.setTimeout(30_000);

      await page.goto("/upload");

      await page.getByRole("button", { name: /Enter ISBN manually/ }).click();

      const isbnInput = page.getByTestId("upload-manual-isbn-input");
      await expect(isbnInput).toBeVisible();

      await isbnInput.fill("9789991234564");
      await page.getByTestId("upload-manual-isbn-submit").click();

      await expect(
        page.getByText("We couldn't find a book with that ISBN")
      ).toBeVisible({
        timeout: 15_000,
      });
    }
  );
});

test.describe("Upload pipeline — duplicate detection", () => {
  /** Upload barcode_isbn_clean.jpg and return once "Already in Your Library" is visible. */
  async function uploadAndWaitForDuplicate(page: Page) {
    await page.goto("/upload");

    const fileChooserPromise = page.waitForEvent("filechooser");
    await page.click("button.btn--primary");
    const fileChooser = await fileChooserPromise;
    await fileChooser.setFiles(
      path.join(__dirname, "../../images/barcode_isbn_clean.jpg")
    );

    await expect(page.getByText("Already in Your Library")).toBeVisible({
      timeout: 60_000,
    });
  }

  test.beforeAll(async ({ browser }) => {
    const context = await browser.newContext({
      storageState: suiteAuthFile("upload"),
    });
    const page = await context.newPage();

    try {
      await page.goto("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/barcode_isbn_clean.jpg")
      );

      await page.getByTestId("upload-loading").waitFor({ timeout: 30_000 });

      const verify = page.getByTestId("upload-verify");
      const duplicateHeading = page.getByText("Already in Your Library");
      const error = page.getByTestId("upload-error");

      await expect(verify.or(duplicateHeading).or(error)).toBeVisible({
        timeout: 60_000,
      });

      if (await error.isVisible()) {
        throw new Error("Upload pipeline failed during duplicate detection setup");
      }

      if (await duplicateHeading.isVisible()) {
        return; // Already placed from a previous run — setup is done.
      }

      await page.getByTestId("upload-confirm-btn").click();
      await page.getByTestId("upload-shelf-picker").waitFor({ timeout: 10_000 });
      await page.getByRole("button", { name: "Library", exact: true }).click();
      await page.getByRole("button", { name: /Add to Library/ }).click();
      await page.getByTestId("upload-complete").waitFor({ timeout: 10_000 });
    } finally {
      await context.close();
    }
  });

  test(
    "duplicate: Already in Your Library heading and all action buttons visible",
    async ({ page }) => {
      test.setTimeout(90_000);
      await uploadAndWaitForDuplicate(page);

      await expect(page.getByRole("button", { name: "Yes, merge" })).toBeVisible();
      await expect(page.getByRole("button", { name: "No, add as separate" })).toBeVisible();
      await expect(page.getByRole("link", { name: "View Book" })).toBeVisible();
      await expect(page.getByRole("button", { name: "Go Back" })).toBeVisible();
    }
  );

  test(
    "duplicate: 'View Book' links to a real book route",
    async ({ page }) => {
      test.setTimeout(90_000);
      await uploadAndWaitForDuplicate(page);

      const viewBookLink = page.getByRole("link", { name: "View Book" });
      await expect(viewBookLink).toBeVisible();
      await expect(viewBookLink).toHaveAttribute("href", /\/books\/.+/);
    }
  );

  test(
    "duplicate: 'Go Back' resets the upload flow to the drop zone",
    async ({ page }) => {
      test.setTimeout(90_000);
      await uploadAndWaitForDuplicate(page);

      await page.getByRole("button", { name: "Go Back" }).click();
      await expect(page.getByTestId("upload-drop-zone")).toBeVisible();
    }
  );

  test(
    "duplicate: 'No, add as separate' proceeds to the verify view",
    async ({ page }) => {
      test.setTimeout(90_000);
      await uploadAndWaitForDuplicate(page);

      await page.getByRole("button", { name: "No, add as separate" }).click();

      const verify = page.getByTestId("upload-verify");
      await expect(verify).toBeVisible({ timeout: 10_000 });

      const verifyText = await verify.textContent();
      const hasRealTitle = /name of the rose/i.test(verifyText ?? "");
      const hasIsbnPlaceholder = /ISBN 978\d{10}/.test(verifyText ?? "");
      if (!hasRealTitle && !hasIsbnPlaceholder) {
        throw new Error(
          `Verify view should show Name of the Rose or ISBN placeholder, got: ${verifyText}`
        );
      }
    }
  );
});

test.describe("Upload pipeline", () => {
  test(
    "identifies multiple books from screenshot_mixed_text.jpg",
    async ({ page }) => {
      test.setTimeout(PIPELINE_TIMEOUT);

      await page.goto("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/screenshot_mixed_text.jpg")
      );

      await expect(page.getByTestId("upload-loading")).toContainText(
        "Reading your photo...",
        { timeout: 60_000 }
      );

      const identified = page.getByTestId("upload-identified");
      const verify = page.getByTestId("upload-verify");
      const error = page.getByTestId("upload-error");
      await expect(identified.or(verify).or(error)).toBeVisible({
        timeout: PIPELINE_TIMEOUT,
      });
      // vacuous-guard-check: allow — fail-fast branch of the always-asserted either/or above; absence is handled by the identified/verify branches.
      if ((await error.count()) > 0) {
        const errorText = await error.textContent();
        throw new Error(`Upload pipeline failed: ${errorText}`);
      }

      // vacuous-guard-check: allow — genuine either/or; the else branch asserts the single-book verify view, so a state is always asserted.
      if ((await identified.count()) > 0) {
        await expect(identified).toContainText("Kite Runner");
        await expect(identified).toContainText("Hosseini");
        await expect(identified).toContainText("Klara");
        await expect(identified).toContainText("Ishiguro");
        await expect(identified).toContainText("Idiot");
        await expect(identified).toContainText("Batuman");
        await expect(identified).toContainText("Things I Don't Want to Know", { ignoreCase: true });
        await expect(identified).toContainText("Levy");
        await expect(identified).toContainText("Cost of Living", { ignoreCase: true });

        const viewBookLinks = identified.locator('a[href^="/books/"]');
        await expect(viewBookLinks).toHaveCount(5);
      } else {
        await expect(verify).toContainText("We think this is");
      }
    }
  );

  test(
    "identifies Train to Crystal City from screenshot_image_reversed_and_cut_off.jpg",
    async ({ page }) => {
      const MAX_ROUNDS = 3;
      test.setTimeout(PIPELINE_TIMEOUT * (MAX_ROUNDS + 1));

      await page.goto("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/screenshot_image_reversed_and_cut_off.jpg")
      );

      await expect(page.getByTestId("upload-loading")).toContainText(
        "Reading your photo...",
        { timeout: 60_000 }
      );

      const verify = page.getByTestId("upload-verify");
      const error = page.getByTestId("upload-error");

      const matches = (text: string) =>
        /crystal city/i.test(text) && /russell/i.test(text);

      const wrongIdentifications: string[] = [];

      for (let round = 1; round <= MAX_ROUNDS; round++) {
        await expect(verify.or(error)).toBeVisible({ timeout: PIPELINE_TIMEOUT });
        if (await error.isVisible()) {
          throw new Error(
            `Upload pipeline failed (round ${round}): ${await error.textContent()}`
          );
        }

        const text = (await verify.textContent()) ?? "";
        if (matches(text)) {
          await expect(verify).toContainText("We think this is");
          await expect(verify).toContainText("Crystal City");
          await expect(verify).toContainText("Russell");
          return;
        }

        if (round === MAX_ROUNDS) {
          throw new Error(
            `Failed to identify Train to Crystal City after ${MAX_ROUNDS} rounds. ` +
              `Wrong identifications: ${wrongIdentifications.join(" | ")} | ` +
              `${text.replace(/\s+/g, " ").trim()}`
          );
        }

        wrongIdentifications.push(text.replace(/\s+/g, " ").trim());

        await page.getByRole("button", { name: /no, try again/i }).click();
        await expect(page.getByTestId("upload-loading")).toContainText(
          "Reading your photo...",
          { timeout: 30_000 }
        );
      }
    }
  );

  test(
    "identifies Flyboys from screenshot_image_reversed.jpg",
    async ({ page }) => {
      test.setTimeout(PIPELINE_TIMEOUT);

      await page.goto("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/screenshot_image_reversed.jpg")
      );

      await expect(page.getByTestId("upload-loading")).toContainText(
        "Reading your photo...",
        { timeout: 60_000 }
      );

      const verify = page.getByTestId("upload-verify");
      const error = page.getByTestId("upload-error");
      await expect(verify.or(error)).toBeVisible({ timeout: PIPELINE_TIMEOUT });
      if (await error.isVisible()) {
        throw new Error(
          `Upload pipeline failed: ${await error.textContent()}`
        );
      }

      await expect(verify).toContainText("We think this is");
      await expect(verify).toContainText("Flyboys");
      await expect(verify).toContainText("Bradley");
    }
  );

  test(
    "identifies Born Again Bodies from screenshot_mildly_obscured.jpg",
    async ({ page }) => {
      test.setTimeout(PIPELINE_TIMEOUT);

      await page.goto("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/screenshot_mildly_obscured.jpg")
      );

      await expect(page.getByTestId("upload-loading")).toContainText(
        "Reading your photo...",
        { timeout: 60_000 }
      );

      const verify = page.getByTestId("upload-verify");
      const error = page.getByTestId("upload-error");
      await expect(verify.or(error)).toBeVisible({ timeout: PIPELINE_TIMEOUT });
      if (await error.isVisible()) {
        throw new Error(
          `Upload pipeline failed: ${await error.textContent()}`
        );
      }

      await expect(verify).toContainText("We think this is");
      await expect(verify).toContainText("Born Again Bodies");
      await expect(verify).toContainText("Griffith");
    }
  );
});

test.describe("Upload pipeline — manual ISBN entry", () => {
  test("invalid ISBN shows checksum error", async ({ page }) => {
    test.setTimeout(15_000);

    await page.goto("/upload");
    await page.getByRole("button", { name: /Enter ISBN manually/i }).click();

    const isbnInput = page.getByTestId("upload-manual-isbn-input");
    await expect(isbnInput).toBeVisible();

    await isbnInput.fill("1234567890");
    await page.getByTestId("upload-manual-isbn-submit").click();

    await expect(page.getByText("Invalid ISBN checksum")).toBeVisible();
  });

  test("valid ISBN-10 is added to the chosen bookshelf", async ({ page }) => {
    test.setTimeout(15_000);

    await page.goto("/upload");
    await page.getByRole("button", { name: /Enter ISBN manually/i }).click();

    const isbnInput = page.getByTestId("upload-manual-isbn-input");
    await isbnInput.fill("0061470767");
    await page.getByRole("button", { name: "Antilibrary" }).click();
    await page.getByTestId("upload-manual-isbn-submit").click();

    const complete = page.getByTestId("upload-complete");
    await expect(complete).toBeVisible({ timeout: 10_000 });
    await expect(complete).toContainText(/Dispossessed/i);
    await expect(complete).toContainText(/Antilibrary/i);
    await expect(page.getByRole("button", { name: "View on shelf" })).toBeVisible();
  });

  test("valid ISBN-13 is added to the chosen bookshelf", async ({ page }) => {
    test.setTimeout(15_000);

    await page.goto("/upload");
    await page.getByRole("button", { name: /Enter ISBN manually/i }).click();

    const isbnInput = page.getByTestId("upload-manual-isbn-input");
    await isbnInput.fill("9780061470769");
    await page.getByTestId("upload-manual-isbn-submit").click();

    await expect(page.getByTestId("upload-complete")).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId("upload-complete")).toContainText(/Dispossessed/i);
  });

  test(
    "recovery: rejected upload → Enter ISBN Manually → real book found",
    async ({ page }) => {
      test.setTimeout(PIPELINE_TIMEOUT + 30_000);

      await page.goto("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/not_a_book.jpg")
      );

      await expect(page.getByTestId("upload-loading")).toContainText(
        "Reading your photo...",
        { timeout: 30_000 }
      );

      await expect(page.getByTestId("upload-error")).toBeVisible({
        timeout: PIPELINE_TIMEOUT,
      });

      await page.getByRole("button", { name: /Enter ISBN Manually/i }).click();
      await expect(page.getByTestId("upload-manual-isbn-input")).toBeVisible();

      await page.getByTestId("upload-manual-isbn-input").fill("9780061470769");
      await page.getByTestId("upload-manual-isbn-submit").click();

      await expect(page.getByTestId("upload-complete")).toBeVisible({
        timeout: 10_000,
      });
      await expect(page.getByTestId("upload-complete")).toContainText(
        /Dispossessed/i
      );
    }
  );
});

// The duplicate notice — the last moment before a reader files a
// second copy. It has Elm program-test coverage on both paths, and had NO
// end-to-end coverage until this block: nothing drove it through a browser
// against a real server, which is exactly how three surfaces in this project
// once shipped fully unstyled.
//
// The governing rule is the owner's standing ruling: the notice INFORMS, it
// never BLOCKS. So each test asserts both halves — the notice is there, and the
// reader can still complete the add. A test that only checked for the text
// would pass just as happily against a flow that had been wedged shut.
test.describe(
  "Upload pipeline — duplicate awareness",
  () => {
    test("manual entry of a book already shelved informs, and still lets the reader add it", async ({
      page,
    }) => {
      test.setTimeout(60_000);

      const isbn = "9780061470769";

      const addOnce = async (shelf: RegExp) => {
        await page.goto("/upload");
        await page.getByRole("button", { name: /Enter ISBN manually/i }).click();
        await page.getByTestId("upload-manual-isbn-input").fill(isbn);
        const choice = page.getByRole("button", { name: shelf });
        if (await choice.isVisible().catch(() => false)) await choice.click();
        await page.getByTestId("upload-manual-isbn-submit").click();
        await expect(page.getByTestId("upload-complete")).toBeVisible({
          timeout: 20_000,
        });
      };

      await addOnce(/Wish List/i);

      await page.goto("/upload");
      await page.getByRole("button", { name: /Enter ISBN manually/i }).click();
      await page.getByTestId("upload-manual-isbn-input").fill(isbn);

      // ⚠️ Deliberately NO pre-submit notice assertion. The manual path is one
      // hop: the client holds only a typed string until the confirm
      // response — which is the FIRST moment the server can name the reader's
      // other bookshelves. `viewCompleteExistingShelvesNotice`'s own doc says
      // exactly this. This spec originally asserted a pre-commit notice that
      // has never existed on this path, and the assertion sat unexecuted
      // behind the Modal project gating.
      const submit = page.getByTestId("upload-manual-isbn-submit");
      await expect(submit).toBeEnabled();

      const antilibrary = page.getByRole("button", { name: /Antilibrary/i });
      if (await antilibrary.isVisible().catch(() => false)) {
        await antilibrary.click();
      }
      await submit.click();

      await expect(page.getByTestId("upload-complete")).toBeVisible({
        timeout: 20_000,
      });
      await expect(page.getByTestId("upload-already-yours")).toContainText(
        /already have this on your/i
      );
    });
  }
);
