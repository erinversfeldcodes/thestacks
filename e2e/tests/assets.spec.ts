/**
 * Asset integrity tests.
 *
 * These tests verify that large binary assets (texture images) are served with
 * real content, not as 132-byte Git LFS pointer stubs. A stub means git-lfs pull
 * was not run before the Docker build, which causes blank bookshelves, missing
 * wallpapers, and a broken login passage animation.
 *
 * Threshold: real textures are 700KB–2MB. Stubs are 132 bytes. 10KB is a
 * conservative minimum that a 1×1 stub can never reach.
 */
import { test, expect } from "@playwright/test";

const TEXTURE_MIN_BYTES = 10_000;

const TEXTURES = [
  "/textures/shelf-walnut-plank.png",
  "/textures/passage-beyond.png",
  "/textures/bookshelf-wide-panoramic.png",
  "/textures/armchair-green-leather.png",
  "/textures/wallpaper-lavender-dragons.png",
  "/textures/wallpaper-damask-green.png",
  "/textures/wallpaper-botanical-cream.png",
  "/textures/wallpaper-floral-watercolour.png",
  "/textures/wallpaper-baby-blue-forest.png",
  "/textures/spine-leather-burgundy.png",
  "/textures/spine-leather-green.png",
  "/textures/spine-leather-navy.png",
  "/textures/spine-cloth-brown.png",
  "/textures/spine-cloth-olive.png",
  "/textures/spine-cloth-red.png",
];

test.describe("Texture assets — LFS pull verification", () => {
  for (const path of TEXTURES) {
    test(`${path} is a real image (>= ${TEXTURE_MIN_BYTES} bytes)`, async ({
      request,
    }) => {
      const response = await request.get(path);
      expect(response.status()).toBe(200);
      const body = await response.body();
      expect(
        body.length,
        `${path} is ${body.length} bytes — looks like a Git LFS pointer stub. Run: git lfs pull`
      ).toBeGreaterThanOrEqual(TEXTURE_MIN_BYTES);
    });
  }
});
